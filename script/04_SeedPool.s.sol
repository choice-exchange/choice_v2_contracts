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
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {BaseScript} from "./BaseScript.sol";

interface IWINJ {
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
}

/**
 * M1 step 5: seed wINJ/USDT on the 0.05% tier and open one full-range position.
 *
 * The tier is the one the plan's §4 table calls 0.05% TOTAL. What goes in the PoolKey is the
 * LP leg of that, 335 pips, because Infinity takes the protocol fee off the input first and
 * the LP fee from what is left. 335 is not a rounded guess: it is what the DEPLOYED
 * ChoiceFeeController returns from getLPFeeFromTotalFee(500), checked on chain before this
 * script was written, and the whole table (67 / 335 / 2011 / 6722) matches §4 exactly.
 *
 * forge script script/04_SeedPool.s.sol:SeedPool -vv --rpc-url $RPC_URL --broadcast
 */
contract SeedPool is BaseScript {
    using CLPoolParametersHelper for bytes32;
    using Planner for Plan;

    /// @notice 0.05% total tier: 335 pips of LP fee, tick spacing 10.
    uint24 internal constant LP_FEE = 335;
    int24 internal constant TICK_SPACING = 10;

    /// @notice 10 USDT per INJ. Testnet seed price, nothing depends on it being the market.
    /// sqrt(10e6 / 1e18) << 96, computed off chain and asserted against the tick below.
    uint160 internal constant SQRT_PRICE_X96 = 250541448375047923607155;

    uint256 internal constant WINJ_SEED = 1e18; // 1 wINJ
    uint256 internal constant USDT_SEED = 10e6; // 10 USDT, matching the seed price

    function run() public {
        address winj = readAddress("external.wINJ");
        address usdt = readAddress("external.usdt");
        address permit2 = readAddress("external.permit2");
        address clPoolManager = readAddress("infinity.clPoolManager");
        address positionManager = readAddress("infinity.clPositionManager");

        // wINJ sorts below USDT (0x00000000... < 0xaDC7...), so currency0 is the 18-decimal
        // leg and currency1 the 6-decimal one. Getting this backwards silently inverts the
        // seed price rather than reverting, so it is asserted rather than assumed.
        require(winj < usdt, "currency ordering: wINJ must sort below USDT");

        uint256 pk = deployerKey();
        address deployer = vm.addr(pk);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(winj),
            currency1: Currency.wrap(usdt),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(clPoolManager),
            fee: LP_FEE,
            parameters: bytes32(0).setTickSpacing(TICK_SPACING)
        });

        // Full range, aligned down/up to the tier's spacing.
        int24 tickLower = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_X96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            WINJ_SEED,
            USDT_SEED
        );
        console.log("liquidity to mint:", liquidity);
        require(liquidity > 0, "zero liquidity: check the seed amounts against the price");

        vm.startBroadcast(pk);

        // --- funding ----------------------------------------------------------------------
        if (IWINJ(winj).balanceOf(deployer) < WINJ_SEED) {
            IWINJ(winj).deposit{value: WINJ_SEED - IWINJ(winj).balanceOf(deployer)}();
            console.log("wrapped INJ; wINJ balance now", IWINJ(winj).balanceOf(deployer));
        }
        require(IERC20(usdt).balanceOf(deployer) >= USDT_SEED, "not enough USDT");

        // --- allowances -------------------------------------------------------------------
        // Two hops, because Infinity's periphery pulls through Permit2 rather than directly:
        // the ERC20 allowance goes to Permit2, and Permit2 is then told which spender may use
        // it. Approving the position manager on the ERC20 alone looks right and moves nothing.
        _approvePermit2(deployer, winj, permit2, positionManager);
        _approvePermit2(deployer, usdt, permit2, positionManager);

        // --- initialize -------------------------------------------------------------------
        (uint160 existing,,,) = ICLPoolManager(clPoolManager).getSlot0(key.toId());
        if (existing == 0) {
            ICLPositionManager(positionManager).initializePool(key, SQRT_PRICE_X96);
            console.log("pool initialized at sqrtPriceX96", SQRT_PRICE_X96);
        } else {
            console.log("pool already initialized at sqrtPriceX96", existing);
        }

        // --- mint one full-range position -------------------------------------------------
        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key,
                tickLower,
                tickUpper,
                uint256(liquidity),
                uint128(WINJ_SEED),
                uint128(USDT_SEED),
                deployer,
                bytes("")
            )
        );
        plan = plan.add(Actions.SETTLE_PAIR, abi.encode(key.currency0, key.currency1));
        ICLPositionManager(positionManager)
            .modifyLiquidities(abi.encode(plan.actions, plan.params), block.timestamp + 600);

        vm.stopBroadcast();

        console.log("poolId:");
        console.logBytes32(PoolId.unwrap(key.toId()));
    }

    function _approvePermit2(address owner, address token, address permit2, address spender) internal {
        if (IERC20(token).allowance(owner, permit2) == 0) {
            IERC20(token).approve(permit2, type(uint256).max);
        }
        IAllowanceTransfer(permit2).approve(token, spender, type(uint160).max, type(uint48).max);
    }
}
