// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {PriceHelper} from "infinity-core/src/pool-bin/libraries/PriceHelper.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {IBinPositionManager} from "infinity-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {BaseScript} from "./BaseScript.sol";

/**
 * M7 step 2: open the FIRST bin pool that has ever existed on this deployment and seed it.
 *
 * ⚠️ This script is the gate on the whole Bin milestone, and not because of what it deploys.
 * `BinPoolManager` has been live since 2026-09-04 and no pool was ever opened on it, so every
 * bin column in `sink/schema.sql`, every bin branch in the substreams and every bin decoder
 * test is derived from the ABI and the upstream source alone - never from a log this chain
 * actually produced. Nothing downstream of here can be verified until this lands.
 *
 * The pair mirrors 04_SeedPool - wINJ/USDT at 10 USDT per INJ - so the indexer's bin numbers
 * can be diffed against a CL pool at the same price. The SIZE is a tenth of the CL pool's, for
 * the funding reason on WINJ_SEED below.
 *
 * ⛔ THIS SCRIPT DOES NOT BROADCAST, and that is not an oversight. wINJ and USDT are MTS bank
 * ERC20s backed by the `0x64` precompile, which has no code for a forked local EVM to execute,
 * so a forge script reverts with "call to non-contract address" on so much as a `balanceOf`.
 * `--skip-simulation` does not help: forge still runs the script body locally to collect the
 * calls (plan §1 item 6, which is also why `04_SeedPool.s.sol` is not what seeded the CL pool).
 *
 * So this is an ENCODER. It derives the active id, the pool id and the `modifyLiquidities`
 * payload - the parts worth keeping in checked Solidity - and prints them for a driver that
 * sends them with `cast`, against a node that has the precompiles:
 *
 *   script/tools/seed-bin-pool.sh
 *
 * Run it alone to see what the driver will send, without sending anything:
 *
 *   forge script script/06_SeedBinPool.s.sol:SeedBinPool -vv --rpc-url $RPC_URL
 */
contract SeedBinPool is BaseScript {
    using BinPoolParametersHelper for bytes32;
    using Planner for Plan;

    /// @notice The LP leg of the 0.05% TOTAL tier, identical to the CL pool's.
    ///
    /// Bin and CL price fees the same way: `ProtocolFeeController` is documented "for both Pool
    /// type" and derives the protocol share from `key.fee`, NOT from anything packed in
    /// `parameters`. So §4's table carries over unchanged and 335 is the same 335.
    uint24 internal constant LP_FEE = 335;

    /// @notice 10 bps of price per bin. The `binStep` axis has no CL analogue: `parameters`
    /// packs it at the same offset 16 that CL packs `tickSpacing` at, so a pool key built with
    /// the wrong helper addresses a different pool rather than reverting.
    ///
    /// In range: the contract enforces `MIN_BIN_STEP` 1 and its `maxBinStep`, 100 by default,
    /// and neither needs a timelock call to open this pool.
    uint16 internal constant BIN_STEP = 10;

    /// @notice 10 USDT per INJ, as an 18-decimal number.
    ///
    /// 🔴 This is the RAW ratio - currency1 base units per currency0 base unit - scaled to 18
    /// decimals, NOT the human price. wINJ is 18dp and USDT is 6dp, so 10 USDT per INJ is
    /// 10e6/1e18 = 1e-11 raw, which is 1e7 here. Feeding the human 10 would seed the pool
    /// twelve orders of magnitude off and it would still initialise cleanly.
    uint256 internal constant SEED_PRICE_18DP = 1e7;

    /// @notice A TENTH of what 04_SeedPool put into the CL pool, at the same price.
    ///
    /// Sized to what the testnet deployer actually holds (0.355 INJ native, 0.110 wINJ), not
    /// to the CL pool: wrapping up to 1 wINJ would need INJ this key does not have, and the
    /// only other funded testnet EOA is the CREATE3 deployer, whose balance is not ours to
    /// spend. The price is identical, so the two pools are still directly comparable per unit
    /// - a bin figure diffed against the CL pool's is off by exactly 10x and nothing else.
    uint128 internal constant WINJ_SEED = 1e17; // 0.1 wINJ, held already - no wrap needed
    uint128 internal constant USDT_SEED = 1e6; // 1 USDT, matching the seed price

    /// @notice Bins either side of the active one that receive liquidity.
    ///
    /// Five bins rather than one, deliberately: a single-bin seed is cheaper but every swap
    /// large enough to empty the active bin reverts, and a bin CROSSING is exactly the event
    /// the indexer has never seen. Three bins hold currency0 (at and above the active id),
    /// three hold currency1 (at and below it), and the active bin holds both.
    uint256 internal constant BIN_COUNT = 5;

    /// @notice Who the seeded position belongs to: the deployer EOA from the address book's
    /// governance block. A constant rather than `vm.addr(deployerKey())`, because this script
    /// never sees the key - the driver holds it - and the position owner is part of the payload
    /// being encoded, so it has to be decided here.
    address internal constant OWNER = 0xAcA0d67c52B503ED15706df5fE29E19677338bc6;

    function run() public view {
        address winj = readAddress("external.wINJ");
        address usdt = readAddress("external.usdt");
        address binPoolManager = readAddress("infinity.binPoolManager");
        address positionManager = readAddress("infinity.binPositionManager");

        // Same ordering assertion as the CL seed: getting it backwards inverts the seed price
        // silently rather than reverting.
        require(winj < usdt, "currency ordering: wINJ must sort below USDT");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(winj),
            currency1: Currency.wrap(usdt),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(binPoolManager),
            fee: LP_FEE,
            parameters: bytes32(0).setBinStep(BIN_STEP)
        });

        uint24 activeId =
            PriceHelper.getIdFromPrice(PriceHelper.convertDecimalPriceTo128x128(SEED_PRICE_18DP), BIN_STEP);
        _requirePriceRoundTrips(activeId);

        // If the pool is already open, the live id wins: the seed must land where the pool
        // actually is, not where this script would have put it. Reading it is safe - the pool
        // manager is ordinary bytecode, unlike the tokens.
        (uint24 existing,,) = IBinPoolManager(binPoolManager).getSlot0(key.toId());
        if (existing != 0) {
            console.log("pool already open; using its live active id instead of the derived one");
            activeId = existing;
        }

        (int256[] memory deltaIds, uint256[] memory distX, uint256[] memory distY) = _spotShape();

        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.BIN_ADD_LIQUIDITY,
            abi.encode(
                IBinPositionManager.BinAddLiquidityParams({
                    poolKey: key,
                    amount0: WINJ_SEED,
                    amount1: USDT_SEED,
                    amount0Max: WINJ_SEED,
                    amount1Max: USDT_SEED,
                    activeIdDesired: activeId,
                    // Zero: the driver reads the live id one call before it sends this, so any
                    // drift is a racing third party and the seed should fail rather than land
                    // somewhere else.
                    idSlippage: 0,
                    deltaIds: deltaIds,
                    distributionX: distX,
                    distributionY: distY,
                    minLiquidities: new uint256[](BIN_COUNT),
                    to: OWNER,
                    hookData: bytes("")
                })
            )
        );
        plan = plan.add(Actions.SETTLE_PAIR, abi.encode(key.currency0, key.currency1));

        console.log("SEED_POOL_MANAGER=%s", binPoolManager);
        console.log("SEED_POSITION_MANAGER=%s", positionManager);
        console.log("SEED_CURRENCY0=%s", winj);
        console.log("SEED_CURRENCY1=%s", usdt);
        console.log("SEED_FEE=%s", uint256(LP_FEE));
        console.log("SEED_BIN_STEP=%s", uint256(BIN_STEP));
        console.log("SEED_ACTIVE_ID=%s", uint256(activeId));
        console.log("SEED_AMOUNT0=%s", uint256(WINJ_SEED));
        console.log("SEED_AMOUNT1=%s", uint256(USDT_SEED));
        console.log("SEED_PARAMETERS=%s", vm.toString(key.parameters));
        console.log("SEED_POOL_ID=%s", vm.toString(PoolId.unwrap(key.toId())));
        console.log("SEED_PAYLOAD=%s", vm.toString(abi.encode(plan.actions, plan.params)));
    }

    /// @dev A flat five-bin spread. currency0 sits at and above the active id, currency1 at and
    /// below it - the bin model's own convention, not a choice - so each distribution is three
    /// non-zero entries that must sum to EXACTLY 1e18. The remainder goes on the first non-zero
    /// entry rather than being divided away, because the position manager checks the sum.
    function _spotShape()
        internal
        pure
        returns (int256[] memory deltaIds, uint256[] memory distX, uint256[] memory distY)
    {
        deltaIds = new int256[](BIN_COUNT);
        distX = new uint256[](BIN_COUNT);
        distY = new uint256[](BIN_COUNT);

        uint256 third = uint256(1e18) / 3;
        uint256 remainder = 1e18 - third * 3;

        for (uint256 i; i < BIN_COUNT; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast) - i < BIN_COUNT, a literal 5.
            deltaIds[i] = int256(i) - 2; // -2, -1, 0, 1, 2
            if (i >= 2) distX[i] = third; // at and above the active bin
            if (i <= 2) distY[i] = third; // at and below the active bin
        }
        distX[2] += remainder;
        distY[0] += remainder;
    }

    /// @dev `getIdFromPrice` walks a logarithm and lands on the bin CONTAINING the price, so it
    /// is lossy by construction. This asserts the loss is under one bin's width, which is the
    /// only guarantee available and enough to catch a mis-scaled price - the failure mode that
    /// otherwise initialises a perfectly healthy pool at the wrong number.
    function _requirePriceRoundTrips(uint24 activeId) internal pure {
        uint256 roundTripped = PriceHelper.convert128x128PriceToDecimal(PriceHelper.getPriceFromId(activeId, BIN_STEP));
        uint256 diff = roundTripped > SEED_PRICE_18DP ? roundTripped - SEED_PRICE_18DP : SEED_PRICE_18DP - roundTripped;
        require(diff * 10_000 <= uint256(BIN_STEP) * SEED_PRICE_18DP, "active id does not round-trip to the seed price");
    }
}
