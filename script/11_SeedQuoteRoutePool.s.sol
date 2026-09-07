// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";

import {BaseScript} from "./BaseScript.sol";
import {BuybackBurnSink} from "../src/fees/BuybackBurnSink.sol";

/**
 * Encode the pool that gives a quote asset its second leg (plan A2), and the `setQuoteRoute`
 * call that registers it.
 *
 * ⛔ **A CALLDATA PRINTER, not a broadcaster.** Every pool here has wINJ on one side, and wINJ is
 * an MTS bank ERC20 backed by the `0x64` precompile, which has no code for a forked local EVM to
 * execute - so a forge script dies on so much as a `balanceOf`, and `--skip-simulation` does not
 * help because forge still runs the body locally. The encoding lives in Solidity, where the
 * compiler checks the `PoolKey` and the action plan; the SENDING lives in
 * `script/tools/seed-quote-route.sh`, which goes at the node with `cast`.
 *
 * 🔑 **ONE-SIDED, and that is not a shortcut.** The sink SELLS the quote asset and RECEIVES
 * `QUOTE`, so the only liquidity this pool ever needs is the side that BUYS the asset - wINJ
 * sitting above spot. A position whose whole range is above the current tick is denominated
 * entirely in `currency0`, so the pool can be opened with no SAI at all, by someone who holds
 * none. What it cannot do is let anyone sell wINJ FOR the asset, which is not a thing the burn
 * loop ever asks for.
 *
 * ⚠️ **The price is a decision, not a discovery.** Nothing on chain says what SAI is worth in
 * wINJ - there is no pool, which is the whole problem - so `SEED_PRICE_TICK` is an assumption
 * somebody has to own, and it bounds what the sink will accept for the asset. On testnet it is
 * chosen; on mainnet it must come from a real market, and if there is no real market then the
 * honest answer is to not accept that quote asset rather than to invent a price for it. See the
 * plan's note on the mainnet SAI/INJ book being $249 in total.
 *
 *   forge script script/11_SeedQuoteRoutePool.s.sol:SeedQuoteRoutePool --rpc-url $RPC_URL
 */
contract SeedQuoteRoutePool is BaseScript {
    using CLPoolParametersHelper for bytes32;
    using Planner for Plan;

    /// 0.05% tier: 335 pips of LP fee, tick spacing 10 - the shape the other seeded pools use.
    uint24 internal constant LP_FEE = 335;
    int24 internal constant TICK_SPACING = 10;

    /// @notice Where the wINJ sits: from here up. The pool opens AT this tick, so the position is
    /// entirely `currency0` and the first sale of the asset fills against it immediately with no
    /// empty gap to cross - a gap would eat the sink's whole `maxImpactBps` allowance and park
    /// the tranche instead of trading it.
    int24 internal constant SEED_PRICE_TICK = 23030; // ~10.003 asset per wINJ
    int24 internal constant SEED_UPPER_TICK = 46050; // ~100 asset per wINJ

    function run() public view {
        address winj = readAddress("external.wINJ");
        address asset = vm.envAddress("ROUTE_ASSET");
        address clPoolManager = readAddress("infinity.clPoolManager");
        address sink = readAddress("choice.buybackBurnSink");
        uint256 amount0 = vm.envOr("ROUTE_WINJ_WEI", uint256(0.1 ether));

        // 🔴 wINJ must sort BELOW the asset, or the whole one-sided argument inverts: the
        // liquidity would have to go BELOW spot and be denominated in the asset, which is the
        // thing whoever runs this does not have. Asserted rather than assumed.
        require(winj < asset, "currency ordering: wINJ must sort below the quote asset");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(winj),
            currency1: Currency.wrap(asset),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(clPoolManager),
            fee: LP_FEE,
            parameters: bytes32(0).setTickSpacing(TICK_SPACING)
        });

        int24 lower = (SEED_PRICE_TICK / TICK_SPACING) * TICK_SPACING;
        int24 upper = (SEED_UPPER_TICK / TICK_SPACING) * TICK_SPACING;
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(lower);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(lower), TickMath.getSqrtRatioAtTick(upper), amount0, 0
        );
        require(liquidity > 0, "zero liquidity: check ROUTE_WINJ_WEI against the ticks");

        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.CL_MINT_POSITION,
            abi.encode(key, lower, upper, uint256(liquidity), uint128(amount0), uint128(0), msg.sender, bytes(""))
        );
        // Only `currency0` is owed, so a single-currency settle is all the plan needs; a
        // SETTLE_PAIR would ask for the asset the whole point is not holding.
        plan = plan.add(Actions.SETTLE, abi.encode(key.currency0, amount0, true));

        console.log("SEED_POOL_MANAGER=%s", vm.toString(clPoolManager));
        console.log("SEED_POSITION_MANAGER=%s", vm.toString(readAddress("infinity.clPositionManager")));
        console.log("SEED_CURRENCY0=%s", vm.toString(winj));
        console.log("SEED_CURRENCY1=%s", vm.toString(asset));
        console.log("SEED_FEE=%s", vm.toString(uint256(LP_FEE)));
        console.log("SEED_PARAMETERS=%s", vm.toString(bytes32(0).setTickSpacing(TICK_SPACING)));
        console.log("SEED_SQRT_PRICE_X96=%s", vm.toString(uint256(sqrtPriceX96)));
        console.log("SEED_AMOUNT0=%s", vm.toString(amount0));
        console.log("SEED_POOL_ID=%s", vm.toString(PoolId.unwrap(key.toId())));
        console.log("SEED_PAYLOAD=%s", vm.toString(abi.encode(plan.actions, plan.params)));
        // The timelock call that registers it, ready to schedule.
        console.log(
            "SEED_SET_ROUTE_CALLDATA=%s",
            vm.toString(abi.encodeCall(BuybackBurnSink.setQuoteRoute, (Currency.wrap(asset), key)))
        );
        console.log("SEED_SINK=%s", vm.toString(sink));
    }
}
