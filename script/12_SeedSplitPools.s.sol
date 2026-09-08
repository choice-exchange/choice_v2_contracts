// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {BaseScript} from "./BaseScript.sol";

/**
 * A mintable test token. `script/`, never `src/` - this is not protocol code and must never
 * ship as any. Public `mint` on purpose: it exists so a testnet operator can size a pool.
 */
contract SplitTestToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * TESTNET SCAFFOLDING: several EQUAL pools on one pair, so the router's SPLIT path can
 * actually be exercised.
 *
 * ⛔ Not part of any deployment. Nothing in `deployments/*.json` points at what this creates
 * and nothing should; it is here so that "a split fires" is a thing somebody can reproduce
 * rather than a thing the unit tests assert alone.
 *
 * ⛔ **This is a CONVENIENCE, never a guarantee.** `SplitTestToken.mint` is public and
 * unowned, and the pools have no hook, so ANY address can mint either token, open a fifth
 * pool on the pair, or trade the four this seeds until they are no longer equal. Nothing here
 * can prevent that and nothing tries to. A test that depends on the fixture must ASSERT the
 * shape it needs - equal quotes at the size it is about to use - and skip rather than fail
 * when the chain has moved on. Re-running this script restores `L`; see the two paragraphs
 * on drift below for what it cannot restore.
 *
 * 🔴 **Why this needs its own pair at all.** A split is only ever returned when it BEATS the
 * best single path, and the allocator drops any leg under its `minShareBps` floor. Every pair
 * on testnet today fails one of those two tests: wINJ/USDT is one CL pool ~450x deeper than
 * the two bin pools beside it, so the bin pools' whole optimal share of a 1,000 wINJ trade is
 * ~0.6% each - correctly refused, and far under the resolution of a 12-point sizing grid
 * anyway. Comparable pools are the missing ingredient, not more pools.
 *
 * 🔑 **Plain ERC20s, deliberately, and NOT wINJ.** wINJ, USDT and every MTS bank ERC20 are
 * backed by the `0x64` precompile, which has no code - so a forge script dies on `balanceOf`
 * and the seeding has to be driven from `cast` (see `seed-quote-route.sh`). A pair this script
 * deploys itself is executable in one broadcast, simulation and all, which is also what lets
 * the split be SWAPPED here rather than merely quoted.
 *
 * 🔑 **What makes the pools equal, and what makes them different.** Same fee, same price, same
 * tick range, same liquidity: identical quotes, so the optimal split is an even one and any
 * skew is the allocator's error rather than the pools'. They differ ONLY in `tickSpacing`,
 * which is part of `PoolKey.parameters` and therefore part of the pool id - the minimum change
 * that yields a fourth pool on one pair. Ticks are multiples of 200 so the SAME range is
 * alignable under every spacing here; a range aligned per-spacing would make the pools
 * unequal in exactly the way this is trying to avoid.
 *
 * 🔴 **FOUR pools, because three cannot tell `SPLIT_CANDIDATES` from the pair.** With three
 * pools a cap of three and a cap of four return the same answer, so the cap is untestable
 * against the chain and a regression in it is invisible. The fourth is what makes the router's
 * leg cap a thing this fixture can measure.
 *
 * ── drift, and what a re-run does about it ────────────────────────────────────────────────
 *
 * 🔑 **Re-running tops every pool up to `TARGET_L`; it never mints a second position.** The
 * old guard skipped a pool with ANY liquidity, which made a partly-seeded run unrepairable -
 * and Injective answers a multi-transaction broadcast with `invalid sequence` often enough
 * that a partly-seeded run is the normal way this finishes. Minting `TARGET_L - current`
 * is idempotent for the same reason the old guard was, and self-healing where it was not.
 *
 * 🔴 **A re-run restores `L`. It cannot restore PRICE, and does not try.** Swapping moves a
 * pool's tick, and no mint moves it back; only an opposing swap does. That is survivable
 * because a SPLIT moves every leg at once, so the pools drift TOGETHER and stay equal to each
 * other, which is the property that matters - all four sat at tick -656 after the first split
 * filled, not at 0. What does diverge them is the allocator's grid remainder, which goes to
 * one leg every time, so the run prints every pool's tick and shouts if they have separated.
 * Re-equalising a diverged pool means swapping it back by hand; there is no honest way to do
 * it from a mint.
 *
 * 🔑 **A pool this run has to CREATE opens at the price the others already carry**, never at
 * 1:1 - a fourth pool initialised at tick 0 beside three at tick -656 is not a fourth equal
 * pool, it is an arbitrage, and every split measured against it would be measuring that.
 *
 *   script/tools/with-key.sh choice-v2-deployer \
 *     SPLIT_TOKEN_A=0x7979AE549fB75e27084fd45816C946e5bD51b5b8 \
 *     SPLIT_TOKEN_B=0x653ca2D344E6A1fa9f3c64c61241a347BFFDf529 \
 *     forge script script/12_SeedSplitPools.s.sol:SeedSplitPools -vv \
 *       --rpc-url $RPC_URL --broadcast --gas-estimate-multiplier 400
 *
 * ⛔ Broadcast WITHOUT `--slow`: forge waits on a receipt testnet cannot serve by hash and
 * strands the run after its first transaction. Verify with `getSlot0`/`getLiquidity`, never
 * with a receipt.
 */
contract SeedSplitPools is BaseScript {
    using CLPoolParametersHelper for bytes32;
    using Planner for Plan;

    /// 0.05% tier's LP leg, the same one every other seeded pool here uses.
    uint24 internal constant LP_FEE = 335;

    /// 🔴 The whole PoolKey difference. Four spacings => four pool ids on one pair.
    int24 internal constant SPACING_A = 10;
    int24 internal constant SPACING_B = 50;
    int24 internal constant SPACING_C = 100;
    int24 internal constant SPACING_D = 200;

    /// Both tokens are 18 decimals and the pools OPENED at 1:1, so `sqrt(1) << 96`. Used only
    /// when no pool on the pair exists yet; after that the live price is the reference.
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// Aligned to 200, which every spacing above divides - see the header. 887200 is also
    /// exactly `MIN_TICK` rounded up to a multiple of 200, so this is the widest usable range
    /// under the coarsest spacing here.
    int24 internal constant TICK_LOWER = -887200;
    int24 internal constant TICK_UPPER = 887200;

    uint256 internal constant SEED_PER_POOL = 1_000 ether;
    uint256 internal constant MINT_TOTAL = 1_000_000 ether;

    /// How far two pools' ticks may sit apart before the fixture stops being a fixture.
    /// One spacing of the coarsest pool: below that they still quote within a hair of each
    /// other, above it a split measured here is measuring the gap instead.
    int24 internal constant TICK_DRIFT_TOLERANCE = SPACING_D;

    function run() public {
        address permit2 = readAddress("external.permit2");
        address clPoolManager = readAddress("infinity.clPoolManager");
        address positionManager = readAddress("infinity.clPositionManager");

        uint256 pk = deployerKey();
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // Reuse the tokens on a re-run rather than stranding the first run's pools beside a
        // second pair nobody asked for.
        address tokenA = vm.envOr("SPLIT_TOKEN_A", address(0));
        address tokenB = vm.envOr("SPLIT_TOKEN_B", address(0));
        if (tokenA == address(0) || tokenB == address(0)) {
            tokenA = address(new SplitTestToken("Split Route Test A", "SPLTA"));
            tokenB = address(new SplitTestToken("Split Route Test B", "SPLTB"));
            SplitTestToken(tokenA).mint(deployer, MINT_TOTAL);
            SplitTestToken(tokenB).mint(deployer, MINT_TOTAL);
        }
        console.log("SPLIT_TOKEN_A", tokenA);
        console.log("SPLIT_TOKEN_B", tokenB);

        // Currency order is the pool's, not ours: currency0 must sort below currency1 or the
        // key addresses a pool that does not exist.
        (address currency0, address currency1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        _approvePermit2(currency0, permit2, positionManager);
        _approvePermit2(currency1, permit2, positionManager);

        int24[4] memory spacings = [SPACING_A, SPACING_B, SPACING_C, SPACING_D];

        // 🔴 Read ONCE, before anything in this run is initialised. A pool created here must
        // open where the pair already trades; taking the reference per pool would let the
        // first pool this run creates become the reference for the next, which is the same
        // number today and a silent trap the moment it is not.
        uint160 priceNow = _referencePrice(clPoolManager, currency0, currency1, spacings);
        console.log("reference sqrtPriceX96", priceNow);

        for (uint256 i; i < spacings.length; ++i) {
            _seed(clPoolManager, positionManager, currency0, currency1, spacings[i], deployer, priceNow);
        }

        vm.stopBroadcast();

        _report(clPoolManager, currency0, currency1, spacings);
    }

    /// The price the pair already trades at, or 1:1 when this is the first run.
    function _referencePrice(address clPoolManager, address currency0, address currency1, int24[4] memory spacings)
        internal
        view
        returns (uint160)
    {
        for (uint256 i; i < spacings.length; ++i) {
            PoolKey memory key = _key(clPoolManager, currency0, currency1, spacings[i]);
            (uint160 existing,,,) = ICLPoolManager(clPoolManager).getSlot0(key.toId());
            if (existing != 0) return existing;
        }
        return SQRT_PRICE_1_1;
    }

    /// The target every pool is topped up to: `L` for `SEED_PER_POOL` of each token over the
    /// full range at the pair's OPENING price. A constant, deliberately - the target must not
    /// move with the live price, or a re-run would hand different pools different `L`.
    function _targetLiquidity() internal pure returns (uint128) {
        uint128 target = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtRatioAtTick(TICK_LOWER),
            TickMath.getSqrtRatioAtTick(TICK_UPPER),
            SEED_PER_POOL,
            SEED_PER_POOL
        );
        require(target > 0, "zero liquidity");
        return target;
    }

    function _key(address clPoolManager, address currency0, address currency1, int24 spacing)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(clPoolManager),
            fee: LP_FEE,
            parameters: bytes32(0).setTickSpacing(spacing)
        });
    }

    function _seed(
        address clPoolManager,
        address positionManager,
        address currency0,
        address currency1,
        int24 spacing,
        address deployer,
        uint160 priceNow
    ) internal {
        PoolKey memory key = _key(clPoolManager, currency0, currency1, spacing);

        console.log("--- tick spacing", uint256(int256(spacing)));
        console.log("    poolId");
        console.logBytes32(PoolId.unwrap(key.toId()));

        (uint160 existing,,,) = ICLPoolManager(clPoolManager).getSlot0(key.toId());
        if (existing == 0) {
            ICLPoolManager(clPoolManager).initialize(key, priceNow);
        }

        // 🔴 TOP UP to the target rather than skipping any pool that already holds something.
        // The old guard ("liquidity > 0 => skip") kept a re-run from double-minting, which is
        // the property that matters and is preserved here - `TARGET_L - current` is zero for a
        // pool that is already right - but it also made an UNDER-seeded pool unrepairable, and
        // a partly-seeded run is the normal outcome of an `invalid sequence` on Injective.
        //
        // ⚠️ `getLiquidity` is the pool's ACTIVE `L`. That is the position's `L` only because
        // every position here is full range, so no price this pair can reach leaves it. Narrow
        // the range and this comparison silently starts reading zero and double-minting.
        uint128 target = _targetLiquidity();
        uint128 current = ICLPoolManager(clPoolManager).getLiquidity(key.toId());
        if (current >= target) {
            console.log("    at target L, skipping", uint256(current));
            return;
        }
        uint128 delta = target - current;
        console.log("    minting L", uint256(delta));

        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.CL_MINT_POSITION,
            abi.encode(key, TICK_LOWER, TICK_UPPER, delta, type(uint128).max, type(uint128).max, deployer, bytes(""))
        );
        bytes memory payload = plan.finalizeModifyLiquidityWithClose(key);
        ICLPositionManager(positionManager).modifyLiquidities(payload, block.timestamp + 600);
    }

    /// What the four pools actually look like now, and whether they are still a fixture.
    ///
    /// 🔑 Printed rather than asserted. This runs after the broadcast, and on Injective some
    /// of that broadcast may not have landed yet - a `require` here would report the node's
    /// lag as a broken fixture. The operator re-runs and reads these four lines.
    function _report(address clPoolManager, address currency0, address currency1, int24[4] memory spacings)
        internal
        view
    {
        console.log("=== pools ===");
        int24 lowest = type(int24).max;
        int24 highest = type(int24).min;
        for (uint256 i; i < spacings.length; ++i) {
            PoolKey memory key = _key(clPoolManager, currency0, currency1, spacings[i]);
            (, int24 tick,,) = ICLPoolManager(clPoolManager).getSlot0(key.toId());
            uint128 liquidity = ICLPoolManager(clPoolManager).getLiquidity(key.toId());
            console.log("    spacing", uint256(int256(spacings[i])));
            console.log("      tick", int256(tick));
            console.log("      L", uint256(liquidity));
            if (tick < lowest) lowest = tick;
            if (tick > highest) highest = tick;
        }
        int24 spread = highest - lowest;
        console.log("    tick spread", int256(spread));
        if (spread > TICK_DRIFT_TOLERANCE) {
            console.log("    !!! the pools have DIVERGED - they no longer quote alike.");
            console.log("    !!! no mint fixes this; swap the leading pool back by hand.");
        }
    }

    /// Two hops: the ERC20 allowance goes to Permit2, then Permit2 is told which spender may
    /// use it. Approving the position manager on the ERC20 alone looks right and moves nothing.
    function _approvePermit2(address token, address permit2, address spender) internal {
        // Skipped when already set: every avoided transaction is one fewer chance for the
        // sequence to run ahead of what the node will accept.
        if (IERC20(token).allowance(msg.sender, permit2) < type(uint128).max) {
            IERC20(token).approve(permit2, type(uint256).max);
        }
        (uint160 allowed,,) = IAllowanceTransfer(permit2).allowance(msg.sender, token, spender);
        if (allowed < type(uint128).max) {
            IAllowanceTransfer(permit2).approve(token, spender, type(uint160).max, type(uint48).max);
        }
    }
}
