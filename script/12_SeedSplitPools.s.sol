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
 * 🔴 **Why this needs its own pair at all.** A split is only ever returned when it BEATS the
 * best single path, and the allocator drops any leg under `minShareBps` (5%). Every pair on
 * testnet today fails one of those two tests: wINJ/USDT has four pools whose depths are
 * $218,697 / $1,503 / $310 / $0, and depth-proportional shares put the thin ones near 0.5% -
 * so the split is correctly refused at every size, and the code path has never run against
 * the chain. Comparable pools are the missing ingredient, not more pools.
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
 * that yields a second pool on one pair. Ticks are multiples of 100 so the SAME range is
 * alignable under every spacing here; a range aligned per-spacing would make the pools
 * unequal in exactly the way this is trying to avoid.
 *
 *   script/tools/with-key.sh choice-v2-deployer \
 *     forge script script/12_SeedSplitPools.s.sol:SeedSplitPools -vv \
 *       --rpc-url $RPC_URL --broadcast
 *
 * ⛔ Broadcast WITHOUT `--slow`: forge waits on a receipt testnet cannot serve by hash and
 * strands the run after its first transaction.
 */
contract SeedSplitPools is BaseScript {
    using CLPoolParametersHelper for bytes32;
    using Planner for Plan;

    /// 0.05% tier's LP leg, the same one every other seeded pool here uses.
    uint24 internal constant LP_FEE = 335;

    /// 🔴 The whole PoolKey difference. Three spacings => three pool ids on one pair.
    int24 internal constant SPACING_A = 10;
    int24 internal constant SPACING_B = 50;
    int24 internal constant SPACING_C = 100;

    /// Both tokens are 18 decimals and the pools open at 1:1, so `sqrt(1) << 96`.
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// Aligned to 100, which every spacing above divides - see the header.
    int24 internal constant TICK_LOWER = -887200;
    int24 internal constant TICK_UPPER = 887200;

    uint256 internal constant SEED_PER_POOL = 1_000 ether;
    uint256 internal constant MINT_TOTAL = 1_000_000 ether;

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

        int24[3] memory spacings = [SPACING_A, SPACING_B, SPACING_C];
        for (uint256 i; i < spacings.length; ++i) {
            _seed(clPoolManager, positionManager, currency0, currency1, spacings[i], deployer);
        }

        vm.stopBroadcast();
    }

    function _seed(
        address clPoolManager,
        address positionManager,
        address currency0,
        address currency1,
        int24 spacing,
        address deployer
    ) internal {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(clPoolManager),
            fee: LP_FEE,
            parameters: bytes32(0).setTickSpacing(spacing)
        });

        console.log("--- tick spacing", uint256(int256(spacing)));
        console.log("    poolId");
        console.logBytes32(PoolId.unwrap(key.toId()));

        (uint160 existing,,,) = ICLPoolManager(clPoolManager).getSlot0(key.toId());
        if (existing == 0) {
            ICLPoolManager(clPoolManager).initialize(key, SQRT_PRICE_1_1);
        }

        // 🔴 Idempotent on the MINT, not just on the initialize. Injective rejected this run's
        // later transactions with `invalid sequence` the first time it was broadcast, so a
        // re-run is the normal way this finishes - and a re-run that minted a SECOND position
        // into the pools that already succeeded would leave them unequal, which is the one
        // property the whole exercise depends on.
        if (ICLPoolManager(clPoolManager).getLiquidity(key.toId()) > 0) {
            console.log("    already seeded, skipping");
            return;
        }

        // 🔴 The SAME liquidity in every pool, computed from the same numbers - not the same
        // token amounts computed per pool. Equal `L` over an equal range is what makes the
        // three quote identically, which is the entire point of the exercise.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtRatioAtTick(TICK_LOWER),
            TickMath.getSqrtRatioAtTick(TICK_UPPER),
            SEED_PER_POOL,
            SEED_PER_POOL
        );
        require(liquidity > 0, "zero liquidity");

        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.CL_MINT_POSITION,
            abi.encode(key, TICK_LOWER, TICK_UPPER, liquidity, type(uint128).max, type(uint128).max, deployer, bytes(""))
        );
        bytes memory payload = plan.finalizeModifyLiquidityWithClose(key);
        ICLPositionManager(positionManager).modifyLiquidities(payload, block.timestamp + 600);
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
