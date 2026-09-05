// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
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
import {IPositionManager} from "infinity-periphery/src/interfaces/IPositionManager.sol";
import {IBinPositionManager} from "infinity-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {BaseScript} from "./BaseScript.sol";

interface IWINJ {
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
}

/**
 * M7 step 2: open the FIRST bin pool that has ever existed on this deployment and seed it.
 *
 * ⚠️ This script is the gate on the whole Bin milestone, and not because of what it deploys.
 * `BinPoolManager` has been live since 2026-09-04 and no pool was ever opened on it, so every
 * bin column in `sink/schema.sql`, every bin branch in the substreams and every bin decoder
 * test is derived from the ABI and the upstream source alone - never from a log this chain
 * actually produced. Nothing downstream of here can be verified until this lands.
 *
 * The pair mirrors 04_SeedPool - wINJ/USDT at 10 USDT per INJ - so the two pools are directly
 * comparable and the indexer's bin numbers can be diffed against a CL pool holding the same
 * value at the same price.
 *
 * 🔴 Broadcast WITHOUT `--slow`. It strands a multi-tx script after the first transaction on
 * Injective EVM, and this one sends four.
 *
 * forge script script/06_SeedBinPool.s.sol:SeedBinPool -vv --rpc-url $RPC_URL --broadcast
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

    uint128 internal constant WINJ_SEED = 1e18; // 1 wINJ
    uint128 internal constant USDT_SEED = 10e6; // 10 USDT, matching the seed price

    /// @notice Bins either side of the active one that receive liquidity.
    ///
    /// Five bins rather than one, deliberately: a single-bin seed is cheaper but every swap
    /// large enough to empty the active bin reverts, and a bin CROSSING is exactly the event
    /// the indexer has never seen. Three bins hold currency0 (at and above the active id),
    /// three hold currency1 (at and below it), and the active bin holds both.
    uint256 internal constant BIN_COUNT = 5;

    function run() public {
        address winj = readAddress("external.wINJ");
        address usdt = readAddress("external.usdt");
        address permit2 = readAddress("external.permit2");
        address binPoolManager = readAddress("infinity.binPoolManager");
        address positionManager = readAddress("infinity.binPositionManager");

        // Same ordering assertion as the CL seed: getting it backwards inverts the seed price
        // silently rather than reverting.
        require(winj < usdt, "currency ordering: wINJ must sort below USDT");

        uint256 pk = deployerKey();
        address deployer = vm.addr(pk);

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
        console.log("active id:", activeId);

        (int256[] memory deltaIds, uint256[] memory distX, uint256[] memory distY) = _spotShape();

        vm.startBroadcast(pk);

        // --- funding ----------------------------------------------------------------------
        if (IWINJ(winj).balanceOf(deployer) < WINJ_SEED) {
            IWINJ(winj).deposit{value: WINJ_SEED - IWINJ(winj).balanceOf(deployer)}();
            console.log("wrapped INJ; wINJ balance now", IWINJ(winj).balanceOf(deployer));
        }
        require(IERC20(usdt).balanceOf(deployer) >= USDT_SEED, "not enough USDT");

        // --- allowances -------------------------------------------------------------------
        // Two hops, because the periphery pulls through Permit2 rather than directly. The
        // spender is the BIN position manager: an approval granted to the CL one moves nothing
        // here and looks identical on a block explorer.
        _approvePermit2(deployer, winj, permit2, positionManager);
        _approvePermit2(deployer, usdt, permit2, positionManager);

        // --- initialize -------------------------------------------------------------------
        // 🔴 Straight at the pool manager, NOT through `BinPositionManager.initializePool`,
        // which wraps the call in `try ... {} catch {}` and swallows every revert. The same
        // reasoning is written up at D15 for the settler; here it is only about the failure
        // being loud, since this pool carries no hook.
        (uint24 existing,,) = IBinPoolManager(binPoolManager).getSlot0(key.toId());
        if (existing == 0) {
            IBinPoolManager(binPoolManager).initialize(key, activeId);
            console.log("pool initialized at active id", activeId);
        } else {
            console.log("pool already initialized at active id", existing);
            activeId = existing;
        }

        // --- seed the five bins -----------------------------------------------------------
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
                    // Zero: this script either just initialised the pool or read the live id
                    // back one call ago, so any drift here is a racing third party and the
                    // seed should fail rather than land somewhere else.
                    idSlippage: 0,
                    deltaIds: deltaIds,
                    distributionX: distX,
                    distributionY: distY,
                    minLiquidities: new uint256[](BIN_COUNT),
                    to: deployer,
                    hookData: bytes("")
                })
            )
        );
        plan = plan.add(Actions.SETTLE_PAIR, abi.encode(key.currency0, key.currency1));
        IPositionManager(positionManager)
            .modifyLiquidities(abi.encode(plan.actions, plan.params), block.timestamp + 600);

        vm.stopBroadcast();

        console.log("poolId:");
        console.logBytes32(PoolId.unwrap(key.toId()));
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

    function _approvePermit2(address owner, address token, address permit2, address spender) internal {
        if (IERC20(token).allowance(owner, permit2) == 0) {
            IERC20(token).approve(permit2, type(uint256).max);
        }
        IAllowanceTransfer(permit2).approve(token, spender, type(uint160).max, type(uint48).max);
    }
}
