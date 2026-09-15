// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {IQuoter} from "infinity-periphery/src/interfaces/IQuoter.sol";
import {ActionConstants} from "infinity-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {ICLRouterBase} from "infinity-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {CLQuoter} from "infinity-periphery/src/pool-cl/lens/CLQuoter.sol";
import {MockInfinityRouter} from "infinity-periphery/test/mocks/MockInfinityRouter.sol";

import {ChoiceFeeController} from "../src/fees/ChoiceFeeController.sol";
import {BuybackBurnSink} from "../src/fees/BuybackBurnSink.sol";
import {IBurnableERC20} from "../src/interfaces/IBurnableERC20.sol";
import {IBurnSink} from "../src/interfaces/IBurnSink.sol";
import {ILaunchpadCore} from "../src/interfaces/ILaunchpadCore.sol";
import {ILaunchPositionLocker} from "../src/interfaces/ILaunchPositionLocker.sol";
import {LaunchFeeCranker} from "../src/launchpad/LaunchFeeCranker.sol";
import {LaunchPoolFeeHook} from "../src/launchpad/LaunchPoolFeeHook.sol";
import {MockBurnableERC20} from "./mocks/MockBurnableERC20.sol";
import {LaunchpadGraduationHarness} from "./LaunchpadGraduation.t.sol";

/// @dev A treasury whose `burn` always reverts: a paused, broken, or mistaken sink.
contract RevertingSink is IBurnSink {
    function burn(Currency, uint256) external pure {
        revert("sink down");
    }
}

/// @notice `LaunchPoolFeeHook` on the real Infinity stack: the UNCHANGED `InfinitySettler`
/// graduates into a hooked pool after the two calls the switch is made of, and every swap shape
/// pays 1% of the gross quote, to the wei, through the router the frontend uses and the quoter
/// that prices it.
///
/// "To the wei" is proven against a TWIN: a hookless pool with the same currencies, price and
/// liquidity and no fee at all, which is exactly the pool the hook wraps. Whatever the twin does
/// with the fee-adjusted amount is what the hooked pool must do with the trader's.
contract LaunchPoolFeeHookTest is LaunchpadGraduationHarness {
    using CLPoolParametersHelper for bytes32;
    using Planner for Plan;

    enum Shape {
        BuyExactIn,
        BuyExactOut,
        SellExactIn,
        SellExactOut
    }

    LaunchPoolFeeHook internal feeHook;
    MockInfinityRouter internal router;
    CLQuoter internal quoter;

    address internal constant NEW_CREATOR = address(0xC0FFEE);
    address internal constant OPS = address(0x0B5);
    uint16 internal constant HOOK_CREATOR_BPS = 7_000;
    uint256 internal constant FEE_PIPS = 10_000;
    uint256 internal constant PIPS = 1_000_000;
    /// @dev beforeInitialize (0) | beforeSwap (6) | afterSwap (7) | both return deltas (10, 11).
    uint16 internal constant BITMAP = 0x0CC1;

    /// @dev A multiple of 100, where the pool's own 1% (rounded up) and the hook's (rounded down)
    /// are the same number - so a hooked buy and today's buy can be compared to the wei.
    uint256 internal constant BUY_QUOTE = 10e18;
    uint256 internal constant BUY_TOKENS = 1_000_000e18;
    uint256 internal constant SELL_TOKENS = 1_000_000e18;
    uint256 internal constant SELL_QUOTE = 5e18;

    function setUp() public override {
        super.setUp();
        router = new MockInfinityRouter(vault, clPoolManager, IBinPoolManager(address(0)));
        quoter = new CLQuoter(address(clPoolManager));
        feeHook =
            new LaunchPoolFeeHook(ILaunchpadCore(address(core)), clPoolManager, OWNER, address(settler), PAD_TREASURY);
        _switchToTheFeeHook();
    }

    /// @dev The two calls the timelock batch makes after deploying the hook, in its order. The
    /// settler is the one already deployed - nothing about it changes but its config.
    function _switchToTheFeeHook() internal {
        vm.prank(OWNER);
        settler.setPoolConfig(0, TICK_SPACING, feeHook);
        feeController.setLaunchPoolGuardHook(feeHook);
    }

    // =====================================================================================
    // Graduation into a hooked pool
    // =====================================================================================

    function test_theUnchangedSettlerGraduatesIntoAHookedPool() public {
        PoolKey memory key = _graduate(false);
        _assertHookedGraduate(key, false);
    }

    function test_theUnchangedSettlerGraduatesIntoAHookedPool_quoteIsCurrency0() public {
        PoolKey memory key = _graduate(true);
        _assertHookedGraduate(key, true);
    }

    function test_theBitmapIsTheWholePermissionSet() public view {
        assertEq(feeHook.getHooksRegistrationBitmap(), BITMAP, "the hook registers a different permission set");
        assertEq(feeHook.BITMAP(), BITMAP);
        assertEq(uint16(uint256(settler.poolParameters())), BITMAP, "the settler keys pools to another bitmap");
        assertEq(feeHook.FEE_PIPS(), FEE_PIPS);
    }

    /// @dev What graduation costs with the hook resolving the launch in `beforeInitialize`. The
    /// on-chain figure is ~1.6M because of the bank-ERC20 transfers no unit test can price; this
    /// pins the part that is ours.
    function test_graduationGasIntoAHookedPool() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, HOOK_CREATOR_BPS);
        uint256 before = gasleft();
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
        uint256 used = before - gasleft();
        emit log_named_uint("triggerGraduation gas into a hooked pool", used);
        assertLt(used, 1_300_000, "graduation into a hooked pool got materially more expensive");
    }

    /// @dev Why the two setters share ONE batch: the settler moved and the controller did not.
    function test_graduationRevertsWhileTheFeeControllerStillGatesTheGuardHook() public {
        feeController.setLaunchPoolGuardHook(guardHook);
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, HOOK_CREATOR_BPS);

        vm.expectRevert(abi.encodeWithSelector(ChoiceFeeController.NotALaunchPool.selector, address(feeHook)));
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
        assertEq(uint8(core.getLaunchState(LAUNCH_ID)), uint8(ILaunchpadCore.LaunchState.CurveFilled));
    }

    /// @dev And the other half: the controller moved and the settler did not.
    function test_graduationRevertsWhileTheSettlerStillKeysTheGuardHook() public {
        vm.prank(OWNER);
        settler.setPoolConfig(LP_FEE, TICK_SPACING, guardHook);
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, HOOK_CREATOR_BPS);

        vm.expectRevert(abi.encodeWithSelector(ChoiceFeeController.NotALaunchPool.selector, address(guardHook)));
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
        assertEq(uint8(core.getLaunchState(LAUNCH_ID)), uint8(ILaunchpadCore.LaunchState.CurveFilled));
    }

    /// @dev The guard's job, kept: nobody but an allowlisted initializer creates a hooked pool.
    function test_onlyAnAllowlistedInitializerCanCreateAHookedPool() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, HOOK_CREATOR_BPS);
        PoolKey memory key = _key();
        uint160 price = _sqrtPriceX96(SEED_TOKEN, SEED_PAIR);
        bytes memory expected = _wrapped(abi.encodeWithSelector(LaunchPoolFeeHook.NotAnInitializer.selector, RANDOM));

        vm.prank(RANDOM);
        vm.expectRevert(expected);
        clPoolManager.initialize(key, price);

        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
        assertEq(uint8(core.getLaunchState(LAUNCH_ID)), uint8(ILaunchpadCore.LaunchState.Graduated));
    }

    /// @dev A settler misconfigured to a non-zero tier would open a pool that charges twice.
    function test_aHookedPoolWithAnLpFeeIsRefused() public {
        vm.prank(OWNER);
        settler.setPoolConfig(LP_FEE, TICK_SPACING, feeHook);
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, HOOK_CREATOR_BPS);

        vm.expectRevert(_wrapped(abi.encodeWithSelector(LaunchPoolFeeHook.LpFeeMustBeZero.selector, LP_FEE)));
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
        assertEq(uint8(core.getLaunchState(LAUNCH_ID)), uint8(ILaunchpadCore.LaunchState.CurveFilled));
    }

    /// @dev Two tokens the core never launched, and a launch token against the wrong quote.
    function test_aPairThatIsNotALaunchIsRefused() public {
        vm.prank(OWNER);
        feeHook.setInitializer(RANDOM, true);
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, HOOK_CREATOR_BPS);
        bytes32 parameters = settler.poolParameters();

        (MockERC20 a, MockERC20 b) = _orderedPair({launchIsCurrency0: true, launchDecimals: 18, pairDecimals: 18});
        PoolKey memory strangers = _hookedKeyOf(address(a), address(b), parameters);
        bytes memory expected = _wrapped(
            abi.encodeWithSelector(LaunchPoolFeeHook.NotALaunchPair.selector, strangers.currency0, strangers.currency1)
        );
        vm.prank(RANDOM);
        vm.expectRevert(expected);
        clPoolManager.initialize(strangers, uint160(1 << 96));

        PoolKey memory wrongQuote = _hookedKeyOf(address(launchToken), address(a), parameters);
        expected = _wrapped(
            abi.encodeWithSelector(
                LaunchPoolFeeHook.NotALaunchPair.selector, wrongQuote.currency0, wrongQuote.currency1
            )
        );
        vm.prank(RANDOM);
        vm.expectRevert(expected);
        clPoolManager.initialize(wrongQuote, uint160(1 << 96));
    }

    /// @dev The canaries do the rest: even an allowlisted initializer cannot open a real launch's
    /// pool unless that launch is mid-graduation through THAT initializer.
    function test_anAllowlistedInitializerCannotOpenALaunchOutsideItsOwnGraduation() public {
        vm.prank(OWNER);
        feeHook.setInitializer(RANDOM, true);
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, HOOK_CREATOR_BPS);
        PoolKey memory key = _key();
        uint160 price = _sqrtPriceX96(SEED_TOKEN, SEED_PAIR);

        // Still trading on the curve.
        bytes memory expected =
            _wrapped(abi.encodeWithSelector(LaunchPoolFeeHook.LayoutMismatch.selector, _launchWord(LAUNCH_ID, 0)));
        vm.prank(RANDOM);
        vm.expectRevert(expected);
        clPoolManager.initialize(key, price);

        // Mid-settlement, but through the launch's own settler, not this caller.
        core.forceState(LAUNCH_ID, ILaunchpadCore.LaunchState.PendingSettlement);
        expected =
            _wrapped(abi.encodeWithSelector(LaunchPoolFeeHook.LayoutMismatch.selector, _launchWord(LAUNCH_ID, 7)));
        vm.prank(RANDOM);
        vm.expectRevert(expected);
        clPoolManager.initialize(key, price);
    }

    /// @dev One launch, one pool: a second pool for a launch already bound is refused, so its
    /// creator credit can only ever be in one currency.
    function test_aLaunchIsBoundToOnePoolOnly() public {
        PoolKey memory key = _graduate(false);
        vm.prank(OWNER);
        feeHook.setInitializer(RANDOM, true);
        PoolKey memory second = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            hooks: key.hooks,
            poolManager: key.poolManager,
            fee: 0,
            parameters: bytes32(uint256(BITMAP)).setTickSpacing(60)
        });
        bytes memory expected =
            _wrapped(abi.encodeWithSelector(LaunchPoolFeeHook.LaunchAlreadyBound.selector, LAUNCH_ID));

        vm.prank(RANDOM);
        vm.expectRevert(expected);
        clPoolManager.initialize(second, uint160(1 << 96));
    }

    // =====================================================================================
    // The fee: every swap shape, both currency orders, to the wei
    // =====================================================================================

    function test_fee_buyExactInput() public {
        _assertShape(false, Shape.BuyExactIn);
    }

    function test_fee_buyExactInput_quoteIsCurrency0() public {
        _assertShape(true, Shape.BuyExactIn);
    }

    function test_fee_buyExactOutput() public {
        _assertShape(false, Shape.BuyExactOut);
    }

    function test_fee_buyExactOutput_quoteIsCurrency0() public {
        _assertShape(true, Shape.BuyExactOut);
    }

    function test_fee_sellExactInput() public {
        _assertShape(false, Shape.SellExactIn);
    }

    function test_fee_sellExactInput_quoteIsCurrency0() public {
        _assertShape(true, Shape.SellExactIn);
    }

    function test_fee_sellExactOutput() public {
        _assertShape(false, Shape.SellExactOut);
    }

    function test_fee_sellExactOutput_quoteIsCurrency0() public {
        _assertShape(true, Shape.SellExactOut);
    }

    /// @dev A buy costs exactly what today's graduate - LP fee 10000, no hook - charges.
    function test_anExactInputBuyCostsWhatTodaysLpFeeCosts() public {
        PoolKey memory key = _graduate(false);
        PoolKey memory today = _openTwin(key, LP_FEE);
        bool zeroForOne = false; // the quote is currency1, and a buy pays it in

        BalanceDelta todays = _twinSwap(today, zeroForOne, -int256(BUY_QUOTE));
        (uint256 paid, uint256 received) = _routerSwap(key, zeroForOne, true, BUY_QUOTE);

        assertEq(paid, _paid(todays, zeroForOne), "a hooked buy spent a different amount");
        assertEq(received, _received(todays, zeroForOne), "a hooked buy does not match today's 1% to the wei");
    }

    /// @dev Exact output rounds the other way: the pool rounds its fee up and the hook rounds
    /// down, so they can differ by one wei of quote, in the trader's favour.
    function test_anExactOutputBuyCostsWhatTodaysLpFeeCostsToAWei() public {
        PoolKey memory key = _graduate(false);
        PoolKey memory today = _openTwin(key, LP_FEE);
        bool zeroForOne = false;

        BalanceDelta todays = _twinSwap(today, zeroForOne, int256(BUY_TOKENS));
        (uint256 paid, uint256 received) = _routerSwap(key, zeroForOne, false, BUY_TOKENS);

        assertEq(received, BUY_TOKENS);
        assertLe(paid, _paid(todays, zeroForOne), "a hooked exact-output buy costs more than today's");
        assertApproxEqAbs(paid, _paid(todays, zeroForOne), 1, "a hooked exact-output buy drifted from today's 1%");
    }

    /// @dev A sell pays 1% of the quote out instead of 1% of the tokens in. The two differ by the
    /// sell's own price impact times 1%: here ~1% of the pool, so ~1 bp of the proceeds.
    function test_aSellCostsWithinItsOwnPriceImpactOfTodaysFee() public {
        PoolKey memory key = _graduate(false);
        PoolKey memory today = _openTwin(key, LP_FEE);
        bool zeroForOne = true; // the launch token is currency0, and a sell pays it in
        uint256 tokens = SEED_TOKEN / 100;

        uint256 todaysProceeds = _received(_twinSwap(today, zeroForOne, -int256(tokens)), zeroForOne);
        (, uint256 hookedProceeds) = _routerSwap(key, zeroForOne, true, tokens);

        assertLt(hookedProceeds, todaysProceeds, "the hooked sell should pay the fee on an output that bore impact");
        assertLe(todaysProceeds - hookedProceeds, todaysProceeds * 2 / 10_000, "more than 1% of a ~1% impact, x2");
    }

    /// @dev The one cost the specified-side fee carries, pinned so it is known rather than found:
    /// a price limit that stops the swap early does not shrink the fee, which was fixed in
    /// `beforeSwap` on the amount asked for.
    function test_aPriceLimitedPartialFillPaysTheFeeOnTheRequestedAmount() public {
        PoolKey memory key = _graduate(false); // a buy is one-for-zero and walks the price up
        Currency quote = key.currency1;
        (uint160 sqrtPriceX96,,,) = clPoolManager.getSlot0(key.toId());
        uint160 limit = uint160(uint256(sqrtPriceX96) * 10_001 / 10_000);
        uint256 amount = 100e18;
        uint256 fee = amount * FEE_PIPS / PIPS;

        pairToken.mint(TRADER, amount);
        uint256 reserveBefore = vault.reservesOfApp(address(clPoolManager), quote);
        uint256 balanceBefore = pairToken.balanceOf(TRADER);
        vm.startPrank(TRADER);
        pairToken.approve(address(swapRouter), amount);
        swapRouter.swap(
            key,
            ICLPoolManager.SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: limit}),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
        vm.stopPrank();

        uint256 paid = balanceBefore - pairToken.balanceOf(TRADER);
        uint256 swapped = vault.reservesOfApp(address(clPoolManager), quote) - reserveBefore;
        assertLt(swapped, amount - fee, "the limit did not bind - the test proves nothing");
        assertEq(vault.balanceOf(address(feeHook), quote), fee, "the fee was not charged on the requested amount");
        assertEq(paid, swapped + fee, "the trader paid something other than the fill plus the whole fee");
    }

    // =====================================================================================
    // Accrual
    // =====================================================================================

    /// @dev D36 on chain: a creator's credit is per launch, the treasury's per quote asset.
    function test_creditIsKeptPerLaunchAndPerQuoteAsset() public {
        PoolKey memory keyA = _graduate(false);
        MockERC20 quoteA = pairToken;
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        PoolKey memory keyB = _graduateAt(LAUNCH_ID + 1, tokenB, quoteA, 5_000);
        MockERC20 tokenC = new MockERC20("C", "C", 18);
        MockERC20 quoteC = new MockERC20("QC", "QC", 18);
        PoolKey memory keyC = _graduateAt(LAUNCH_ID + 2, tokenC, quoteC, 9_000);

        _buy(keyA, address(quoteA), BUY_QUOTE);
        _buy(keyB, address(quoteA), 2 * BUY_QUOTE);
        _buy(keyC, address(quoteC), 3 * BUY_QUOTE);

        uint256 feeA = BUY_QUOTE / 100;
        uint256 feeB = 2 * BUY_QUOTE / 100;
        uint256 feeC = 3 * BUY_QUOTE / 100;
        uint256 creatorA = feeA * HOOK_CREATOR_BPS / 10_000;
        uint256 creatorB = feeB * 5_000 / 10_000;
        uint256 creatorC = feeC * 9_000 / 10_000;

        assertEq(feeHook.creatorOwed(LAUNCH_ID), creatorA, "launch A's creator credit");
        assertEq(feeHook.creatorOwed(LAUNCH_ID + 1), creatorB, "launch B's creator credit");
        assertEq(feeHook.creatorOwed(LAUNCH_ID + 2), creatorC, "launch C's creator credit");
        assertEq(feeHook.treasuryOwed(Currency.wrap(address(quoteA))), feeA - creatorA + feeB - creatorB);
        assertEq(feeHook.treasuryOwed(Currency.wrap(address(quoteC))), feeC - creatorC);
        assertEq(vault.balanceOf(address(feeHook), Currency.wrap(address(quoteA))), feeA + feeB, "claims in A's quote");
        assertEq(vault.balanceOf(address(feeHook), Currency.wrap(address(quoteC))), feeC, "claims in C's quote");
        assertEq(Currency.unwrap(feeHook.launchQuote(LAUNCH_ID + 2)), address(quoteC));
    }

    /// @dev The invariant the payouts rest on, over any sequence of trades: the vault claims the
    /// hook holds are exactly what it has credited, and both pots drain to nothing.
    function testFuzz_theHooksClaimsAreAlwaysExactlyItsCredits(
        uint8[4] memory shapes,
        uint64[4] memory amounts,
        bool quoteIsCurrency0
    ) public {
        PoolKey memory key = _graduate(quoteIsCurrency0);
        Currency quote = Currency.wrap(address(pairToken));
        for (uint256 i; i < 4; ++i) {
            Shape shape = Shape(shapes[i] % 4);
            (bool zeroForOne, bool exactInput) = _direction(shape, quoteIsCurrency0);
            _routerSwap(key, zeroForOne, exactInput, _bounded(shape, amounts[i]));
            assertEq(
                vault.balanceOf(address(feeHook), quote),
                feeHook.creatorOwed(LAUNCH_ID) + feeHook.treasuryOwed(quote),
                "the hook's claims are not its credits"
            );
            assertEq(vault.balanceOf(address(feeHook), Currency.wrap(address(launchToken))), 0, "a launch-token fee");
        }

        if (feeHook.creatorOwed(LAUNCH_ID) > 0) {
            vm.prank(CREATOR);
            feeHook.claimCreator(LAUNCH_ID);
        }
        if (feeHook.treasuryOwed(quote) > 0) feeHook.harvest(quote);
        assertEq(vault.balanceOf(address(feeHook), quote), 0, "claims left over after both pots were paid");
    }

    // =====================================================================================
    // Claims
    // =====================================================================================

    function test_onlyTheCurrentCreatorCanClaim() public {
        PoolKey memory key = _graduate(false);
        _buy(key, address(pairToken), BUY_QUOTE);
        Currency quote = Currency.wrap(address(pairToken));
        uint256 owed = feeHook.creatorOwed(LAUNCH_ID);
        assertGt(owed, 0, "nothing credited - the test proves nothing");

        vm.prank(RANDOM);
        vm.expectRevert(abi.encodeWithSelector(LaunchPoolFeeHook.NotCreator.selector, RANDOM, CREATOR));
        feeHook.claimCreator(LAUNCH_ID);

        vm.prank(CREATOR);
        assertEq(feeHook.claimCreator(LAUNCH_ID), owed, "claimed a different amount");
        assertEq(pairToken.balanceOf(CREATOR), owed, "the creator was not paid in the quote");
        assertEq(feeHook.creatorOwed(LAUNCH_ID), 0, "the credit was not cleared");
        assertEq(
            vault.balanceOf(address(feeHook), quote), feeHook.treasuryOwed(quote), "claims left do not match the rest"
        );

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(LaunchPoolFeeHook.NothingToClaim.selector, LAUNCH_ID));
        feeHook.claimCreator(LAUNCH_ID);
    }

    /// @dev Decision A: a handoff after graduation moves the pool fees with the creator role.
    function test_aCreatorHandoffAfterGraduationMovesThePoolFeesWithIt() public {
        PoolKey memory key = _graduate(false);
        _buy(key, address(pairToken), BUY_QUOTE);
        uint256 owed = feeHook.creatorOwed(LAUNCH_ID);

        vm.prank(CREATOR);
        core.transferCreator(LAUNCH_ID, NEW_CREATOR);
        vm.prank(NEW_CREATOR);
        core.acceptCreator(LAUNCH_ID);
        assertEq(feeHook.creatorOf(LAUNCH_ID), NEW_CREATOR, "the hook does not see the handoff");

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(LaunchPoolFeeHook.NotCreator.selector, CREATOR, NEW_CREATOR));
        feeHook.claimCreator(LAUNCH_ID);

        vm.prank(NEW_CREATOR);
        feeHook.claimCreator(LAUNCH_ID);
        assertEq(pairToken.balanceOf(NEW_CREATOR), owed, "the new creator was not paid");
        assertEq(pairToken.balanceOf(CREATOR), 0, "the old creator was paid");
    }

    function test_claimingALaunchThisHookNeverBoundReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchPoolFeeHook.UnknownLaunch.selector, uint256(999)));
        feeHook.claimCreator(999);
    }

    // =====================================================================================
    // Harvest
    // =====================================================================================

    /// @dev Where the mainnet treasury starts: the sink's reserved address, which has no code yet.
    function test_harvestToATreasuryWithNoCodeDeliversAndCallsNothing() public {
        PoolKey memory key = _graduate(false);
        _buy(key, address(pairToken), BUY_QUOTE);
        Currency quote = Currency.wrap(address(pairToken));
        uint256 owed = feeHook.treasuryOwed(quote);
        assertEq(PAD_TREASURY.code.length, 0);

        vm.expectEmit(true, true, false, true, address(feeHook));
        emit LaunchPoolFeeHook.Harvested(quote, PAD_TREASURY, owed, false);
        vm.prank(RANDOM);
        feeHook.harvest(quote);

        assertEq(pairToken.balanceOf(PAD_TREASURY), owed, "the treasury was not paid");
        assertEq(feeHook.treasuryOwed(quote), 0, "the credit was not cleared");

        vm.expectRevert(abi.encodeWithSelector(LaunchPoolFeeHook.NothingToHarvest.selector, quote));
        feeHook.harvest(quote);
    }

    function test_aHarvestWhoseSinkRevertsStillDelivers() public {
        RevertingSink broken = new RevertingSink();
        vm.prank(OWNER);
        feeHook.setTreasury(address(broken));
        PoolKey memory key = _graduate(false);
        _buy(key, address(pairToken), BUY_QUOTE);
        Currency quote = Currency.wrap(address(pairToken));
        uint256 owed = feeHook.treasuryOwed(quote);

        vm.expectEmit(true, true, false, true, address(feeHook));
        emit LaunchPoolFeeHook.Harvested(quote, address(broken), owed, false);
        feeHook.harvest(quote);
        assertEq(pairToken.balanceOf(address(broken)), owed, "the sink's revert undid the delivery");
    }

    /// @dev The buy-and-burn, end to end: the burn token graduates like any launch into a hooked
    /// pool, that pool is the buyback pool, and `harvest` pays the real sink, which buys and burns.
    function test_harvestIntoARealSinkBuysAndBurns() public {
        PoolKey memory key = _graduate(false);
        MockBurnableERC20 burnToken = new MockBurnableERC20("Burn", "BURN", 18);
        PoolKey memory burnPool = _graduateAt(LAUNCH_ID + 1, MockERC20(address(burnToken)), pairToken, HOOK_CREATOR_BPS);
        BuybackBurnSink sink = _deploySink(burnToken, burnPool);
        vm.prank(OWNER);
        feeHook.setTreasury(address(sink));

        _buy(key, address(pairToken), 100e18);
        Currency quote = Currency.wrap(address(pairToken));
        uint256 owed = feeHook.treasuryOwed(quote);
        uint256 supplyBefore = burnToken.totalSupply();

        vm.expectEmit(true, true, false, true, address(feeHook));
        emit LaunchPoolFeeHook.Harvested(quote, address(sink), owed, true);
        vm.prank(RANDOM);
        feeHook.harvest(quote);

        assertLt(burnToken.totalSupply(), supplyBefore, "nothing was burnt");
        assertGt(burnToken.balanceOf(OPS), 0, "the ops share never arrived");
        assertEq(pairToken.balanceOf(address(sink)), 0, "the sink did not spend what it was paid");

        // The buyback is a buy through a hooked pool, so it paid the hook 1% like any trader: 70%
        // to the burn token's creator and the rest back into the treasury's credit.
        uint256 buybackFee = owed * FEE_PIPS / PIPS;
        uint256 toCreator = buybackFee * HOOK_CREATOR_BPS / 10_000;
        assertEq(feeHook.creatorOwed(LAUNCH_ID + 1), toCreator, "the buyback's creator share");
        assertEq(feeHook.treasuryOwed(quote), buybackFee - toCreator, "the buyback's treasury share");
    }

    // =====================================================================================
    // The neighbours: harmless on a hooked graduate
    // =====================================================================================

    /// @dev The locked seed earns no LP fee on a hooked pool, so every leg of a crank is a no-op
    /// that still succeeds. A keeper that keeps a hooked graduate in its list wastes gas, nothing more.
    function test_theCrankerIsAHarmlessNoOpOnAHookedGraduate() public {
        PoolKey memory key = _graduate(false);
        MockBurnableERC20 burnToken = new MockBurnableERC20("Burn", "BURN", 18);
        PoolKey memory burnPool = _graduateAt(LAUNCH_ID + 1, MockERC20(address(burnToken)), pairToken, HOOK_CREATOR_BPS);
        BuybackBurnSink sink = _deploySink(burnToken, burnPool);
        LaunchFeeCranker cranker = new LaunchFeeCranker(ILaunchPositionLocker(address(locker)), sink, OWNER);
        vm.prank(OWNER);
        locker.setLaunchpadTreasury(address(sink));

        _buy(key, address(pairToken), BUY_QUOTE);
        _sell(key, address(pairToken), SELL_TOKENS);
        Currency quote = Currency.wrap(address(pairToken));
        uint256 creatorBefore = feeHook.creatorOwed(LAUNCH_ID);
        uint256 treasuryBefore = feeHook.treasuryOwed(quote);

        vm.prank(RANDOM);
        LaunchFeeCranker.Crank memory result = cranker.crank(LAUNCH_ID);

        assertEq(result.collected0 + result.collected1, 0, "the locked seed earned an LP fee on a hooked pool");
        assertEq(result.claimed0 + result.claimed1, 0, "the locker paid something out");
        assertEq(pairToken.balanceOf(address(sink)), 0, "the sink received quote");
        assertEq(launchToken.balanceOf(address(sink)), 0, "the sink received the launch token");
        assertEq(feeHook.creatorOwed(LAUNCH_ID), creatorBefore, "the crank touched the creator's credit");
        assertEq(feeHook.treasuryOwed(quote), treasuryBefore, "the crank touched the treasury's credit");

        uint256[] memory ids = new uint256[](1);
        ids[0] = LAUNCH_ID;
        assertTrue(cranker.crankMany(ids)[0], "crankMany reports the hooked graduate as failed");
    }

    /// @dev The sink resolves a hooked graduate through the locker like any other and, holding none
    /// of its token, finds nothing to sell.
    function test_theSinksConvertIsAHarmlessNoOpOnAHookedGraduate() public {
        PoolKey memory key = _graduate(false);
        MockBurnableERC20 burnToken = new MockBurnableERC20("Burn", "BURN", 18);
        PoolKey memory burnPool = _graduateAt(LAUNCH_ID + 1, MockERC20(address(burnToken)), pairToken, HOOK_CREATOR_BPS);
        BuybackBurnSink sink = _deploySink(burnToken, burnPool);
        _buy(key, address(pairToken), BUY_QUOTE);
        Currency quote = Currency.wrap(address(pairToken));
        uint256 claims = vault.balanceOf(address(feeHook), quote);

        vm.prank(RANDOM);
        sink.convert(Currency.wrap(address(launchToken)), LAUNCH_ID);

        assertEq(launchToken.balanceOf(address(sink)), 0);
        assertEq(pairToken.balanceOf(address(sink)), 0);
        assertEq(vault.balanceOf(address(feeHook), quote), claims, "the convert moved the hook's claims");
    }

    // =====================================================================================
    // The owner has no lever over a live pool
    // =====================================================================================

    function test_noOwnerActionChangesWhatALivePoolCharges() public {
        PoolKey memory key = _graduate(false);
        Currency quote = key.currency1;
        _routerSwap(key, false, true, BUY_QUOTE);

        vm.startPrank(OWNER);
        feeHook.setInitializer(address(settler), false);
        feeHook.setTreasury(RANDOM);
        feeHook.transferOwnership(RANDOM);
        vm.stopPrank();

        uint256 claimsBefore = vault.balanceOf(address(feeHook), quote);
        (uint256 paid,) = _routerSwap(key, false, true, BUY_QUOTE);
        assertEq(paid, BUY_QUOTE, "the swap no longer works the same");
        assertEq(vault.balanceOf(address(feeHook), quote) - claimsBefore, BUY_QUOTE / 100, "the fee moved");
        (bool registered, uint256 launchId,, uint16 creatorBps) = feeHook.poolInfo(key.toId());
        assertTrue(registered);
        assertEq(launchId, LAUNCH_ID);
        assertEq(creatorBps, HOOK_CREATOR_BPS, "the split moved");
    }

    function test_onlyTheOwnerConfigures() public {
        Currency quote = Currency.wrap(address(pairToken));
        vm.startPrank(RANDOM);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDOM));
        feeHook.setInitializer(RANDOM, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDOM));
        feeHook.setTreasury(RANDOM);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDOM));
        feeHook.sweep(quote, RANDOM);
        vm.stopPrank();

        vm.startPrank(OWNER);
        vm.expectRevert(LaunchPoolFeeHook.ZeroAddress.selector);
        feeHook.setInitializer(address(0), true);
        vm.expectRevert(abi.encodeWithSelector(LaunchPoolFeeHook.InvalidTreasury.selector, address(0)));
        feeHook.setTreasury(address(0));
        vm.expectRevert(abi.encodeWithSelector(LaunchPoolFeeHook.InvalidTreasury.selector, address(feeHook)));
        feeHook.setTreasury(address(feeHook));
        vm.stopPrank();
    }

    /// @dev The hook never holds a token of its own, so a sweep can take a stray balance whole and
    /// still cannot reach a vault claim.
    function test_sweepTakesOnlyTokensSentHereByMistake() public {
        PoolKey memory key = _graduate(false);
        _buy(key, address(pairToken), BUY_QUOTE);
        Currency quote = Currency.wrap(address(pairToken));
        uint256 claims = vault.balanceOf(address(feeHook), quote);
        pairToken.mint(address(feeHook), 1e18);

        vm.prank(OWNER);
        assertEq(feeHook.sweep(quote, RANDOM), 1e18, "swept a different amount");
        assertEq(pairToken.balanceOf(RANDOM), 1e18);
        assertEq(vault.balanceOf(address(feeHook), quote), claims, "the sweep reached the vault claims");
    }

    function test_onlyThePoolManagerCanCallTheCallbacks() public {
        PoolKey memory key = _graduate(false);
        ICLPoolManager.SwapParams memory params =
            ICLPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        vm.startPrank(RANDOM);
        vm.expectRevert(LaunchPoolFeeHook.NotPoolManager.selector);
        feeHook.beforeSwap(RANDOM, key, params, "");
        vm.expectRevert(LaunchPoolFeeHook.NotPoolManager.selector);
        feeHook.afterSwap(RANDOM, key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(LaunchPoolFeeHook.NotPoolManager.selector);
        feeHook.beforeInitialize(address(settler), key, uint160(1 << 96));
        vm.expectRevert(LaunchPoolFeeHook.UnexpectedLock.selector);
        feeHook.lockAcquired(abi.encode(key.currency1, RANDOM, uint256(1)));
        vm.stopPrank();
    }

    // =====================================================================================
    // Gas
    // =====================================================================================

    /// @dev What the hook adds to a swap through the router, measured after a warm-up swap on each
    /// pool so neither pays a first-ever storage write. The testnet walk measures the same thing
    /// on chain; this is the number to compare it with.
    function test_swapGasWithAndWithoutTheHook() public {
        PoolKey memory key = _graduate(false);
        PoolKey memory today = _openTwin(key, LP_FEE);
        uint256 hooked = _measureBuy(key);
        uint256 plain = _measureBuy(today);
        emit log_named_uint("buy, exact input, router: hooked graduate", hooked);
        emit log_named_uint("buy, exact input, router: today's graduate", plain);
        assertGt(hooked, plain);
        assertLt(hooked - plain, 100_000, "the hook got materially more expensive per swap");
    }

    // =====================================================================================
    // Helpers
    // =====================================================================================

    /// @dev Graduate `LAUNCH_ID` through the unchanged settler, with the quote on the given side.
    function _graduate(bool quoteIsCurrency0) internal returns (PoolKey memory key) {
        (launchToken, pairToken) =
            _orderedPair({launchIsCurrency0: !quoteIsCurrency0, launchDecimals: 18, pairDecimals: 18});
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, HOOK_CREATOR_BPS);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
        key = _key();
    }

    function _graduateAt(uint256 launchId, MockERC20 token, MockERC20 pair, uint16 creatorBps)
        internal
        returns (PoolKey memory key)
    {
        core.seedLaunch(
            launchId, CREATOR, address(token), IERC20(address(pair)), address(settler), SEED_PAIR, creatorBps
        );
        token.mint(address(core), SEED_TOKEN);
        pair.mint(address(core), SEED_PAIR);
        core.triggerGraduation(launchId, SEED_TOKEN);
        key = _hookedKeyOf(address(token), address(pair), settler.poolParameters());
    }

    function _hookedKeyOf(address a, address b, bytes32 parameters) internal view returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: feeHook,
            poolManager: IPoolManager(address(clPoolManager)),
            fee: 0,
            parameters: parameters
        });
    }

    function _assertHookedGraduate(PoolKey memory key, bool quoteIsCurrency0) internal view {
        assertEq(uint8(core.getLaunchState(LAUNCH_ID)), uint8(ILaunchpadCore.LaunchState.Graduated), "not graduated");
        assertEq(address(key.hooks), address(feeHook), "the pool is not keyed to the fee hook");
        assertEq(key.fee, 0, "the pool carries an LP fee");
        assertEq(uint16(uint256(key.parameters)), BITMAP, "the key's bitmap is not the hook's");
        assertEq(
            Currency.unwrap(quoteIsCurrency0 ? key.currency0 : key.currency1), address(pairToken), "test setup: order"
        );

        (uint160 sqrtPriceX96,, uint24 protocolFee, uint24 lpFee) = clPoolManager.getSlot0(key.toId());
        assertGt(sqrtPriceX96, 0, "no pool");
        assertEq(protocolFee, 0, "a hooked graduate pays Choice a protocol fee");
        assertEq(lpFee, 0, "the pool itself charges a fee");

        (bool registered, uint256 launchId, Currency quote, uint16 creatorBps) = feeHook.poolInfo(key.toId());
        assertTrue(registered, "the hook never bound the pool");
        assertEq(launchId, LAUNCH_ID, "bound to the wrong launch");
        assertEq(Currency.unwrap(quote), address(pairToken), "the hook took the wrong side for the quote");
        assertEq(creatorBps, HOOK_CREATOR_BPS, "the creator share decoded from the core is wrong");
        assertEq(PoolId.unwrap(feeHook.launchPool(LAUNCH_ID)), PoolId.unwrap(key.toId()));

        // The locker still holds the seed, for the liquidity. It simply earns nothing now.
        uint256 tokenId = locker.getPosition(LAUNCH_ID).tokenId;
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(locker), "the seed is not locked");
        _assertPoolPriceMatchesRatio(key, SEED_TOKEN, SEED_PAIR);
    }

    /// @dev Buying spends quote; selling spends the launch token. Exact input specifies the input.
    function _direction(Shape shape, bool quoteIsCurrency0) internal pure returns (bool zeroForOne, bool exactInput) {
        bool buy = shape == Shape.BuyExactIn || shape == Shape.BuyExactOut;
        exactInput = shape == Shape.BuyExactIn || shape == Shape.SellExactIn;
        zeroForOne = buy == quoteIsCurrency0;
    }

    function _assertShape(bool quoteIsCurrency0, Shape shape) internal {
        PoolKey memory key = _graduate(quoteIsCurrency0);
        PoolKey memory twin = _openTwin(key, 0);
        Currency quote = Currency.wrap(address(pairToken));
        (bool zeroForOne, bool exactInput) = _direction(shape, quoteIsCurrency0);

        // What the twin does with the fee-adjusted amount is what the hooked pool must do.
        uint256 amount;
        uint256 fee;
        uint256 expectedPaid;
        uint256 expectedReceived;
        if (shape == Shape.BuyExactIn) {
            amount = BUY_QUOTE;
            fee = amount * FEE_PIPS / PIPS;
            expectedPaid = amount;
            expectedReceived = _received(_twinSwap(twin, zeroForOne, -int256(amount - fee)), zeroForOne);
        } else if (shape == Shape.BuyExactOut) {
            amount = BUY_TOKENS;
            uint256 poolIn = _paid(_twinSwap(twin, zeroForOne, int256(amount)), zeroForOne);
            fee = poolIn * FEE_PIPS / (PIPS - FEE_PIPS);
            expectedPaid = poolIn + fee;
            expectedReceived = amount;
        } else if (shape == Shape.SellExactIn) {
            amount = SELL_TOKENS;
            uint256 poolOut = _received(_twinSwap(twin, zeroForOne, -int256(amount)), zeroForOne);
            fee = poolOut * FEE_PIPS / PIPS;
            expectedPaid = amount;
            expectedReceived = poolOut - fee;
        } else {
            amount = SELL_QUOTE;
            fee = amount * FEE_PIPS / (PIPS - FEE_PIPS);
            expectedPaid = _paid(_twinSwap(twin, zeroForOne, int256(amount + fee)), zeroForOne);
            expectedReceived = amount;
        }
        assertGt(fee, 0, "the case takes no fee - it proves nothing");

        uint256 quoted = _quoteSwap(key, zeroForOne, exactInput, amount);
        (uint256 paid, uint256 received) = _routerSwap(key, zeroForOne, exactInput, amount);

        assertEq(paid, expectedPaid, "the trader paid the wrong amount");
        assertEq(received, expectedReceived, "the trader received the wrong amount");
        assertEq(quoted, exactInput ? received : paid, "the quoter disagrees with the executed swap");

        uint256 toCreator = fee * HOOK_CREATOR_BPS / 10_000;
        assertEq(vault.balanceOf(address(feeHook), quote), fee, "the hook's claims are not the fee");
        assertEq(feeHook.creatorOwed(LAUNCH_ID), toCreator, "the creator's credit");
        assertEq(feeHook.treasuryOwed(quote), fee - toCreator, "the treasury's credit");
        assertEq(vault.balanceOf(address(feeHook), Currency.wrap(address(launchToken))), 0, "a launch-token fee");
    }

    /// @dev A hookless pool with the hooked graduate's currencies, spacing, price and liquidity, and
    /// no protocol fee. With `lpFee` 0 it is the pool the hook wraps; with `LP_FEE`, today's graduate.
    function _openTwin(PoolKey memory hooked, uint24 lpFee) internal returns (PoolKey memory twin) {
        twin = PoolKey({
            currency0: hooked.currency0,
            currency1: hooked.currency1,
            hooks: IHooks(address(0)),
            poolManager: hooked.poolManager,
            fee: lpFee,
            parameters: bytes32(0).setTickSpacing(TICK_SPACING)
        });
        (uint160 sqrtPriceX96,,,) = clPoolManager.getSlot0(hooked.toId());
        uint128 liquidity = clPoolManager.getLiquidity(hooked.toId());

        // Born without a protocol fee, like a graduate. Under the controller an ordinary pool pays one.
        clPoolManager.setProtocolFeeController(IProtocolFeeController(address(0)));
        clPoolManager.initialize(twin, sqrtPriceX96);
        clPoolManager.setProtocolFeeController(feeController);

        MockERC20(Currency.unwrap(twin.currency0)).mint(address(this), 1e30);
        MockERC20(Currency.unwrap(twin.currency1)).mint(address(this), 1e30);
        MockERC20(Currency.unwrap(twin.currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(twin.currency1)).approve(address(swapRouter), type(uint256).max);
        swapRouter.modifyPosition(
            twin,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING,
                tickUpper: (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        assertEq(clPoolManager.getLiquidity(twin.toId()), liquidity, "the twin's liquidity differs");
        (,, uint24 protocolFee,) = clPoolManager.getSlot0(twin.toId());
        assertEq(protocolFee, 0, "the twin pays a protocol fee");
    }

    function _twinSwap(PoolKey memory twin, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta delta)
    {
        delta = swapRouter.swap(
            twin,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    /// @dev A swap the way the frontend builds one: a single CL swap action, then settle-all and
    /// take-all to the trader, through the Infinity router the UniversalRouter embeds.
    function _routerSwap(PoolKey memory key, bool zeroForOne, bool exactInput, uint256 amount)
        internal
        returns (uint256 paid, uint256 received)
    {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        IERC20 tokenIn = IERC20(Currency.unwrap(input));
        IERC20 tokenOut = IERC20(Currency.unwrap(output));
        MockERC20(address(tokenIn)).mint(TRADER, 1e30);

        Plan memory plan = Planner.init();
        if (exactInput) {
            plan = plan.add(
                Actions.CL_SWAP_EXACT_IN_SINGLE,
                abi.encode(
                    ICLRouterBase.CLSwapExactInputSingleParams({
                        poolKey: key,
                        zeroForOne: zeroForOne,
                        amountIn: uint128(amount),
                        amountOutMinimum: 0,
                        hookData: ""
                    })
                )
            );
        } else {
            plan = plan.add(
                Actions.CL_SWAP_EXACT_OUT_SINGLE,
                abi.encode(
                    ICLRouterBase.CLSwapExactOutputSingleParams({
                        poolKey: key,
                        zeroForOne: zeroForOne,
                        amountOut: uint128(amount),
                        amountInMaximum: type(uint128).max,
                        hookData: ""
                    })
                )
            );
        }
        bytes memory data = plan.finalizeSwap(input, output, ActionConstants.MSG_SENDER);

        uint256 inBefore = tokenIn.balanceOf(TRADER);
        uint256 outBefore = tokenOut.balanceOf(TRADER);
        vm.startPrank(TRADER);
        tokenIn.approve(address(router), type(uint256).max);
        router.executeActions(data);
        vm.stopPrank();
        paid = inBefore - tokenIn.balanceOf(TRADER);
        received = tokenOut.balanceOf(TRADER) - outBefore;
    }

    function _quoteSwap(PoolKey memory key, bool zeroForOne, bool exactInput, uint256 amount)
        internal
        returns (uint256 quoted)
    {
        IQuoter.QuoteExactSingleParams memory params = IQuoter.QuoteExactSingleParams({
            poolKey: key, zeroForOne: zeroForOne, exactAmount: uint128(amount), hookData: ""
        });
        if (exactInput) {
            (quoted,) = quoter.quoteExactInputSingle(params);
        } else {
            (quoted,) = quoter.quoteExactOutputSingle(params);
        }
    }

    function _buy(PoolKey memory key, address quote, uint256 amount) internal returns (uint256 received) {
        (, received) = _routerSwap(key, Currency.unwrap(key.currency0) == quote, true, amount);
    }

    function _sell(PoolKey memory key, address quote, uint256 tokens) internal returns (uint256 received) {
        (, received) = _routerSwap(key, Currency.unwrap(key.currency1) == quote, true, tokens);
    }

    function _measureBuy(PoolKey memory key) internal returns (uint256 used) {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(pairToken);
        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.CL_SWAP_EXACT_IN_SINGLE,
            abi.encode(
                ICLRouterBase.CLSwapExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountIn: uint128(BUY_QUOTE),
                    amountOutMinimum: 0,
                    hookData: ""
                })
            )
        );
        bytes memory data = plan.finalizeSwap(
            zeroForOne ? key.currency0 : key.currency1,
            zeroForOne ? key.currency1 : key.currency0,
            ActionConstants.MSG_SENDER
        );
        pairToken.mint(TRADER, 2 * BUY_QUOTE);
        vm.prank(TRADER);
        pairToken.approve(address(router), type(uint256).max);

        vm.prank(TRADER);
        router.executeActions(data); // warm-up: a first-ever write is not what a swap costs
        vm.prank(TRADER);
        uint256 before = gasleft();
        router.executeActions(data);
        used = before - gasleft();
    }

    function _deploySink(MockBurnableERC20 burnToken, PoolKey memory buybackPool)
        internal
        returns (BuybackBurnSink sink)
    {
        sink = new BuybackBurnSink(
            IBurnableERC20(address(burnToken)), Currency.wrap(address(pairToken)), vault, posm, OPS, OWNER, 5_000, 7_000
        );
        address[] memory lockers = new address[](1);
        lockers[0] = address(locker);
        vm.startPrank(OWNER);
        sink.setBuybackPool(buybackPool);
        sink.setLockers(lockers);
        sink.setGuards(0.0001 ether, 500, 1 hours);
        vm.stopPrank();
    }

    /// @dev Quote amounts up to ~3% of the raise, token amounts up to ~2.5% of the seed.
    function _bounded(Shape shape, uint64 raw) internal pure returns (uint256) {
        if (shape == Shape.BuyExactIn || shape == Shape.SellExactOut) return bound(uint256(raw), 1e6, 50e18);
        return bound(uint256(raw), 1e6, 5_000_000e18);
    }

    function _paid(BalanceDelta delta, bool zeroForOne) internal pure returns (uint256) {
        int128 amount = zeroForOne ? delta.amount0() : delta.amount1();
        return uint256(uint128(-amount));
    }

    function _received(BalanceDelta delta, bool zeroForOne) internal pure returns (uint256) {
        int128 amount = zeroForOne ? delta.amount1() : delta.amount0();
        return uint256(uint128(amount));
    }

    /// @dev How the pool manager reports a hook's `beforeInitialize` revert (ERC-7751).
    function _wrapped(bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(feeHook),
            ICLHooks.beforeInitialize.selector,
            reason,
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    function _launchWord(uint256 launchId, uint256 offset) internal view returns (bytes32) {
        bytes32 base = keccak256(abi.encode(launchId, uint256(12)));
        return core.extsload(bytes32(uint256(base) + offset), 1)[0];
    }
}
