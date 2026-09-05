// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import {CLPositionManager} from "infinity-periphery/src/pool-cl/CLPositionManager.sol";
import {ICLPositionDescriptor} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionDescriptor.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";

import {ChoiceFeeController} from "../src/fees/ChoiceFeeController.sol";
import {IBurnSink} from "../src/interfaces/IBurnSink.sol";
import {ILaunchpadCore} from "../src/interfaces/ILaunchpadCore.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {InfinitySettler} from "../src/launchpad/InfinitySettler.sol";
import {LaunchPoolGuardHook} from "../src/launchpad/LaunchPoolGuardHook.sol";
import {PositionLocker} from "../src/launchpad/PositionLocker.sol";
import {MockLaunchpadCore} from "./mocks/MockLaunchpadCore.sol";

/// @dev An ERC20 that hands control to one designated recipient on transfer - the shape of a
/// native leg, where `Currency.transfer` forwards all gas, without needing a native pool.
contract HookingERC20 is MockERC20 {
    address public hookTarget;

    constructor() MockERC20("HOOK", "HOOK", 18) {}

    function setHookTarget(address target) external {
        hookTarget = target;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (to == hookTarget && to != address(0)) IReenterHook(to).hook();
        return ok;
    }
}

interface IReenterHook {
    function hook() external;
}

/// @dev A creator that tries to claim again while being paid. `collect` no longer transfers
/// anything, so the only moment a recipient gets control is inside its own `claim`.
contract ReenteringCreator is IReenterHook {
    PositionLocker internal immutable LOCKER;
    uint256 internal immutable LAUNCH_ID_;

    Currency public reentryCurrency;
    bool public tried;
    bool public reentryReverted;

    constructor(PositionLocker locker, uint256 launchId) {
        LOCKER = locker;
        LAUNCH_ID_ = launchId;
    }

    function arm(Currency currency) external {
        reentryCurrency = currency;
    }

    function hook() external override {
        if (tried) return;
        tried = true;
        try LOCKER.claim(reentryCurrency, address(this)) {
            reentryReverted = false;
        } catch {
            reentryReverted = true;
        }
    }
}

/// @notice M4: a launchpad launch graduates onto a Choice v2 CL pool in one transaction, the
/// seed position is locked forever, and the fees it earns split three ways - creator and
/// launchpad through `PositionLocker.collect`, Choice through `ChoiceFeeController.harvest`.
///
/// The whole Infinity stack is real here (Vault, CLPoolManager, CLPositionManager, Permit2,
/// the deployed fee controller); only `LaunchpadCore` is a stand-in, and that one is
/// layout-faithful on purpose - see `MockLaunchpadCore`.
contract LaunchpadGraduationTest is Test, DeployPermit2 {
    using CLPoolParametersHelper for bytes32;
    using Planner for Plan;

    Vault internal vault;
    CLPoolManager internal clPoolManager;
    CLPositionManager internal posm;
    IAllowanceTransfer internal permit2;
    CLPoolManagerRouter internal swapRouter;
    ChoiceFeeController internal feeController;

    MockLaunchpadCore internal core;
    PositionLocker internal locker;
    InfinitySettler internal settler;
    LaunchPoolGuardHook internal guardHook;

    MockERC20 internal launchToken;
    MockERC20 internal pairToken;

    address internal constant OWNER = address(0x71E); // the timelock, on chain
    address internal constant CREATOR = address(0xC12A);
    address internal constant PAD_TREASURY = address(0xDADD);
    address internal constant CHOICE_TREASURY = address(0xC401);
    address internal constant RANDOM = address(0xBEEF);
    address internal constant TRADER = address(0x77AD);

    uint256 internal constant LAUNCH_ID = 42;
    /// @dev Post-curve residue plus the graduation reserve, 18 decimals.
    uint256 internal constant SEED_TOKEN = 206_900_000e18;
    /// @dev What the curve raised, 18 decimals (wINJ-shaped).
    uint256 internal constant SEED_PAIR = 1_500e18;
    uint16 internal constant CREATOR_BPS = 1_000; // 10% of LP fees to the creator

    uint24 internal constant LP_FEE = 6722; // the 1.00% tier's LP leg
    int24 internal constant TICK_SPACING = 200;

    function setUp() public {
        vault = new Vault();
        clPoolManager = new CLPoolManager(vault);
        vault.registerApp(address(clPoolManager));

        // The real revenue path: graduated pools are initialised by the settler, so the
        // protocol fee they carry is whatever this controller hands the pool manager.
        feeController = new ChoiceFeeController(address(clPoolManager), CHOICE_TREASURY, IBurnSink(address(0)));
        clPoolManager.setProtocolFeeController(feeController);

        permit2 = IAllowanceTransfer(deployPermit2());
        posm = new CLPositionManager(
            vault, clPoolManager, permit2, 100_000, ICLPositionDescriptor(address(0)), IWETH9(address(new WETH()))
        );
        swapRouter = new CLPoolManagerRouter(vault, clPoolManager);

        core = new MockLaunchpadCore();

        // The locker and the hook both have to know the settler, and the settler has to know
        // both of them. On chain that circle is closed by CREATE3, whose address depends only
        // on the salt; here by predicting the CREATE address. Either way all three contracts
        // are born owned by the timelock, with no post-deploy wiring to forget.
        address predictedSettler = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        locker = new PositionLocker(posm, PAD_TREASURY, OWNER, predictedSettler);
        guardHook = new LaunchPoolGuardHook(OWNER, predictedSettler);
        settler =
            new InfinitySettler(ILaunchpadCore(address(core)), clPoolManager, posm, permit2, locker, guardHook, OWNER);
        assertEq(address(settler), predictedSettler, "settler address prediction is wrong");

        (launchToken, pairToken) = _orderedPair({launchIsCurrency0: true, launchDecimals: 18, pairDecimals: 18});
    }

    // =====================================================================================
    // Graduation
    // =====================================================================================

    function test_graduatesAtomicallyAndLocksTheSeed() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);

        assertEq(
            uint8(core.getLaunchState(LAUNCH_ID)),
            uint8(ILaunchpadCore.LaunchState.Graduated),
            "launch is not Graduated in the same tx"
        );
        assertTrue(core.settledCallbackFired(LAUNCH_ID), "onSettled never fired");

        PositionLocker.LockedPosition memory position = locker.getPosition(LAUNCH_ID);
        assertEq(position.tokenId, 1, "first position should be tokenId 1");
        assertEq(position.creator, CREATOR, "creator decoded from the core is wrong");
        assertEq(position.creatorBps, CREATOR_BPS, "creator share decoded from the core is wrong");
        assertEq(IERC721(address(posm)).ownerOf(position.tokenId), address(locker), "seed is not locked");
        assertGt(locker.positionLiquidity(LAUNCH_ID), 0, "seed position has no liquidity");
    }

    /// @dev What graduation now costs. It runs inside `triggerGraduation`, which the pad
    /// prices for a keeper or a user, and Injective's `eth_estimateGas` under-reports - so
    /// the number belongs in a test rather than in someone's gas limit by guesswork.
    function test_graduationGasBudget() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);

        uint256 before = gasleft();
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
        uint256 used = before - gasleft();

        emit log_named_uint("triggerGraduation gas (pool init + full-range mint + callback)", used);
        assertLt(used, 1_200_000, "graduation got materially more expensive; re-check the pad's gas limits");
    }

    /// @dev D14: full range at `realPair / poolTokenAmount` is the entire price policy.
    function test_poolOpensAtTheCurveRatio() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);

        _assertPoolPriceMatchesRatio(_key(), SEED_TOKEN, SEED_PAIR);
    }

    /// @dev Sorting is by address, so the launch token is currency0 for roughly half of all
    /// launches and currency1 for the rest. Getting it backwards inverts the price silently.
    function test_poolOpensAtTheCurveRatio_whenLaunchTokenSortsSecond() public {
        (launchToken, pairToken) = _orderedPair({launchIsCurrency0: false, launchDecimals: 18, pairDecimals: 18});
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);

        _assertPoolPriceMatchesRatio(_key(), SEED_TOKEN, SEED_PAIR);
    }

    /// @dev A 6-decimal quote against an 18-decimal launch token is the USDT case, and the
    /// raw-unit price there is ~1e-17 - the far end of the sqrt-price math.
    function test_poolOpensAtTheCurveRatio_withSixDecimalQuote() public {
        (launchToken, pairToken) = _orderedPair({launchIsCurrency0: true, launchDecimals: 18, pairDecimals: 6});
        uint256 seedPair = 30_000e6;
        _prepareLaunch(SEED_TOKEN, seedPair, CREATOR_BPS);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);

        _assertPoolPriceMatchesRatio(_key(), SEED_TOKEN, seedPair);
    }

    /// @dev Zero surplus is the D14 claim. Full range at the curve's own ratio consumes both
    /// legs to within rounding, and whatever is left is dust the owner can sweep.
    function test_bothLegsAreConsumedToDust() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);

        uint256 tokenResidue = launchToken.balanceOf(address(settler));
        uint256 pairResidue = pairToken.balanceOf(address(settler));
        assertLt(tokenResidue, SEED_TOKEN / 1e12, "launch-token residue is not dust");
        assertLt(pairResidue, SEED_PAIR / 1e12, "pair residue is not dust");
        assertEq(launchToken.balanceOf(address(vault)), SEED_TOKEN - tokenResidue, "pool did not get the seed");
        assertEq(pairToken.balanceOf(address(vault)), SEED_PAIR - pairResidue, "pool did not get the raise");
    }

    /// @dev The launchpad's S-L2: the settler forwards the amount it was handed, never its
    /// own balance, so a donation cannot reprice the pool a launch graduates into.
    function test_donationBeforeGraduationStaysOutOfThePool() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        uint256 donation = 50_000_000e18;
        launchToken.mint(address(settler), donation);

        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);

        _assertPoolPriceMatchesRatio(_key(), SEED_TOKEN, SEED_PAIR);
        assertGe(launchToken.balanceOf(address(settler)), donation, "donation was swept into the pool");

        vm.prank(OWNER);
        uint256 swept = settler.sweep(Currency.wrap(address(launchToken)), OWNER);
        assertGe(swept, donation, "donation and dust are not recoverable");
    }

    // =====================================================================================
    // Fees
    // =====================================================================================

    /// @dev The M4 "done when", end to end: a swap on the graduated pool pays the LP position
    /// (creator + launchpad, through the locker) AND Choice (through the fee controller).
    function test_swapFeesReachCreatorLaunchpadAndChoice() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);

        _swap(_key(), true, 10e18);
        _swap(_key(), false, 1e18);

        // Choice's leg.
        Currency pairCurrency = Currency.wrap(address(pairToken));
        assertGt(feeController.pendingProtocolFee(pairCurrency), 0, "protocol fee did not accrue");
        vm.prank(RANDOM);
        (uint256 toTreasury,) = feeController.harvest(pairCurrency);
        assertEq(pairToken.balanceOf(CHOICE_TREASURY), toTreasury, "Choice treasury not paid");
        assertGt(toTreasury, 0, "Choice earned nothing");

        // The launchpad's leg. Permissionless, like the harvest.
        uint128 liquidityBefore = locker.positionLiquidity(LAUNCH_ID);
        vm.prank(RANDOM);
        (uint256 amount0, uint256 amount1) = locker.collect(LAUNCH_ID);
        assertGt(amount0, 0, "no launch-token fees collected");
        assertGt(amount1, 0, "no pair fees collected");

        (Currency currency0, Currency currency1) = _currencies();
        _assertSplit(currency0, amount0, CREATOR_BPS);
        _assertSplit(currency1, amount1, CREATOR_BPS);

        assertEq(locker.positionLiquidity(LAUNCH_ID), liquidityBefore, "collect moved liquidity");
        assertEq(IERC721(address(posm)).ownerOf(1), address(locker), "collect moved the position");
    }

    function test_collectWithZeroCreatorShareSendsEverythingToTheLaunchpad() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, 0);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
        _swap(_key(), true, 10e18);

        (uint256 amount0, uint256 amount1) = locker.collect(LAUNCH_ID);
        assertGt(amount0 + amount1, 0, "no fees collected");
        assertEq(locker.owed(Currency.wrap(address(pairToken)), CREATOR), 0, "creator credited a zero share");
        assertEq(locker.owed(Currency.wrap(address(launchToken)), CREATOR), 0, "creator credited a zero share");

        (Currency currency0, Currency currency1) = _currencies();
        _assertSplit(currency0, amount0, 0);
        _assertSplit(currency1, amount1, 0);
    }

    /// @dev The transient guard on `collect`. A creator that gets control mid-payout must not
    /// be able to run a second collect inside the first.
    function test_collectRefusesToReenter() public {
        HookingERC20 hookToken = new HookingERC20();
        // Order the pair so the hooking token is the launch token.
        while (address(hookToken) >= address(pairToken)) {
            pairToken = new MockERC20("PAIR", "PAIR", 18);
        }
        launchToken = MockERC20(address(hookToken));

        ReenteringCreator badCreator = new ReenteringCreator(locker, LAUNCH_ID);
        core.seedLaunch(
            LAUNCH_ID,
            address(badCreator),
            address(launchToken),
            IERC20(address(pairToken)),
            address(settler),
            SEED_PAIR,
            CREATOR_BPS
        );
        launchToken.mint(address(core), SEED_TOKEN);
        pairToken.mint(address(core), SEED_PAIR);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);

        // Fees accrue in the INPUT token of a swap, so trade both ways to earn some of the
        // hooking token - otherwise the creator is never paid in it and never gets control.
        _swap(_key(), false, 10e18);
        _swap(_key(), true, 100_000e18);
        hookToken.setHookTarget(address(badCreator));

        locker.collect(LAUNCH_ID);

        Currency hooking = Currency.wrap(address(hookToken));
        uint256 credited = locker.owed(hooking, address(badCreator));
        assertGt(credited, 0, "the creator was never credited - the test proves nothing");

        badCreator.arm(hooking);
        locker.claim(hooking, address(badCreator));

        assertTrue(badCreator.tried(), "the creator never got control - the test proves nothing");
        assertTrue(badCreator.reentryReverted(), "a reentrant claim went through");
        // The property, whichever mechanism enforced it: paid exactly once.
        assertEq(hookToken.balanceOf(address(badCreator)), credited, "the creator was paid twice");
        assertEq(locker.owed(hooking, address(badCreator)), 0, "the credit was not cleared");
    }

    function test_collectRevertsWhenThereIsNothingToCollect() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);

        vm.expectRevert(abi.encodeWithSelector(PositionLocker.NothingToCollect.selector, LAUNCH_ID));
        locker.collect(LAUNCH_ID);
    }

    function test_collectRevertsForAnUnregisteredLaunch() public {
        vm.expectRevert(abi.encodeWithSelector(PositionLocker.NotRegistered.selector, uint256(7)));
        locker.collect(7);
    }

    /// @dev A donation sitting on the locker must not be paid out as if it were fee revenue.
    /// The reason `collect` credits instead of pushing. Four transfers in one call meant any
    /// one recipient that could not be paid froze the OTHER side's fees too, permanently -
    /// `creator` is snapshotted at graduation and nothing here can skip a leg or re-route it.
    function test_anUnpayableCreatorDoesNotStrandTheLaunchpad() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
        _swap(_key(), true, 10e18);
        _swap(_key(), false, 1e18);

        // The shape of a quote asset with a transfer blocklist, or of a creator contract that
        // reverts on a native leg: this recipient cannot be paid in this currency, ever.
        Currency pair = Currency.wrap(address(pairToken));
        vm.mockCallRevert(address(pairToken), abi.encodeWithSelector(IERC20.transfer.selector, CREATOR), "BLACKLISTED");

        vm.prank(RANDOM);
        (, uint256 amount1) = locker.collect(LAUNCH_ID);
        assertGt(amount1, 0, "no pair fees collected - the test proves nothing");

        // The creator's own claim is the only thing that fails.
        vm.expectRevert();
        locker.claim(pair, CREATOR);

        // The launchpad's share is unaffected, and so is the other currency entirely.
        uint256 treasuryOwed = locker.owed(pair, PAD_TREASURY);
        assertGt(treasuryOwed, 0, "launchpad was credited nothing");
        vm.prank(RANDOM);
        locker.claim(pair, PAD_TREASURY);
        assertEq(pairToken.balanceOf(PAD_TREASURY), treasuryOwed, "launchpad could not be paid");

        // And the creator's credit is still there, waiting, not burnt.
        assertGt(locker.owed(pair, CREATOR), 0, "the creator's credit was lost");
        assertGt(locker.owed(Currency.wrap(address(launchToken)), CREATOR), 0, "the other leg was lost too");
    }

    /// The coupling the pull payment creates. Fees now sit here between `collect` and
    /// `claim`, so `sweep` has to subtract them - otherwise liveness was traded for custody.
    function test_sweepCannotReachCreditedFees() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
        _swap(_key(), true, 10e18);
        _swap(_key(), false, 1e18);

        uint256 donation = 1_000e18;
        pairToken.mint(address(locker), donation);

        Currency pair = Currency.wrap(address(pairToken));
        (, uint256 amount1) = locker.collect(LAUNCH_ID);
        assertEq(locker.totalOwed(pair), amount1, "collected fees were not reserved");

        vm.prank(OWNER);
        uint256 swept = locker.sweep(pair, RANDOM);
        assertEq(swept, donation, "sweep took more (or less) than the donation");
        assertEq(pairToken.balanceOf(RANDOM), donation, "sweep paid out the wrong amount");

        // Everything owed is still here and still claimable.
        locker.claim(pair, CREATOR);
        locker.claim(pair, PAD_TREASURY);
        assertEq(
            pairToken.balanceOf(CREATOR) + pairToken.balanceOf(PAD_TREASURY), amount1, "fees survived the sweep short"
        );
    }

    /// `ownerOf` is a presence check. The binding `register` writes is permanent, so it also
    /// has to be a position in the pool the settler just seeded.
    function test_registerRejectsAPositionInAnotherPool() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);

        // A position in a DIFFERENT pool that this contract nonetheless holds - the shape a
        // mid-graduation mint to the locker would have taken.
        uint256 strayTokenId = _mintPositionTo(address(locker));
        assertEq(IERC721(address(posm)).ownerOf(strayTokenId), address(locker));

        PoolKey memory otherPool = _key();
        otherPool.fee = 500; // same legs and hook, a tier the graduation did not use

        vm.prank(address(settler));
        vm.expectRevert(abi.encodeWithSelector(PositionLocker.PositionPoolMismatch.selector, strayTokenId));
        locker.register(99, strayTokenId, CREATOR, CREATOR_BPS, otherPool);
    }

    function test_donationToTheLockerIsNotSplitAsFees() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
        _swap(_key(), true, 10e18);

        uint256 donation = 1_000e18;
        pairToken.mint(address(locker), donation);

        (, uint256 amount1) = locker.collect(LAUNCH_ID);
        Currency pair = Currency.wrap(address(pairToken));
        _claimIfAny(pair, CREATOR);
        _claimIfAny(pair, PAD_TREASURY);
        assertEq(pairToken.balanceOf(CREATOR), amount1 * CREATOR_BPS / 10_000, "donation leaked into the split");
        assertEq(pairToken.balanceOf(address(locker)), donation, "donation was paid out");
    }

    // =====================================================================================
    // The camped-pool grief, and the way out of it
    // =====================================================================================

    /// @dev The grief this hook exists for: initialising an Infinity pool is free and
    /// permissionless, and a launch token's address is public from bind time. Without the
    /// guard, anyone could open the pool a graduation is going to use, at a price of their
    /// choosing, and take the difference from the seed on the first arb.
    function test_grieferCannotCreateTheGraduationPool() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        PoolKey memory key = _key();

        vm.prank(RANDOM);
        vm.expectRevert();
        clPoolManager.initialize(key, _sqrtPriceX96(SEED_TOKEN, SEED_PAIR * 100));

        // 🔴 Through the position manager it does not even revert: `initializePool` wraps the
        // pool manager in a try/catch and swallows every error, returning `type(int24).max`.
        // So the griefer's attempt is a silent no-op - and this is exactly why the settler
        // initialises through the pool manager directly, where a rejection is loud.
        vm.prank(RANDOM);
        int24 swallowed = posm.initializePool(key, _sqrtPriceX96(SEED_TOKEN, SEED_PAIR * 100));
        assertEq(swallowed, type(int24).max, "the position manager did not swallow the rejection");

        (uint160 price,,,) = clPoolManager.getSlot0(key.toId());
        assertEq(price, 0, "the pool exists, so somebody got in");

        // And graduation still works, at the curve's own ratio.
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
        _assertPoolPriceMatchesRatio(_key(), SEED_TOKEN, SEED_PAIR);
    }

    /// @dev The consolation prize a griefer still has: a HOOKLESS pool for the same pair. It
    /// is a different `PoolKey`, so it is a different pool - empty, unrouted, and irrelevant.
    function test_aGrieferHooklessPoolDoesNotTouchTheGraduation() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        (Currency currency0, Currency currency1) = _currencies();
        PoolKey memory junk = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(clPoolManager)),
            fee: settler.lpFee(),
            parameters: bytes32(0).setTickSpacing(settler.tickSpacing())
        });

        vm.prank(RANDOM);
        posm.initializePool(junk, _sqrtPriceX96(SEED_TOKEN, SEED_PAIR * 100));
        assertTrue(PoolId.unwrap(junk.toId()) != PoolId.unwrap(_key().toId()), "same pool, not a different key");

        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
        _assertPoolPriceMatchesRatio(_key(), SEED_TOKEN, SEED_PAIR);
        assertGt(locker.positionLiquidity(LAUNCH_ID), 0);
    }

    /// @dev The guard is an allowlist, not a hard-coded address, so a settler can be replaced
    /// without stranding the launches the old one graduated.
    function test_ownerCanAllowAndRevokeAnInitializer() public {
        assertTrue(guardHook.isInitializer(address(settler)));

        vm.prank(OWNER);
        guardHook.setInitializer(RANDOM, true);
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        // Resolve the key BEFORE pranking: `_key()` calls the settler, and the first external
        // call would otherwise spend the prank.
        PoolKey memory key = _key();
        uint160 price = _sqrtPriceX96(SEED_TOKEN, SEED_PAIR);
        vm.prank(RANDOM);
        clPoolManager.initialize(key, price); // now allowed

        vm.prank(OWNER);
        guardHook.setInitializer(address(settler), false);
        (launchToken, pairToken) = _orderedPair({launchIsCurrency0: true, launchDecimals: 18, pairDecimals: 18});
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        vm.expectRevert();
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
    }

    function test_onlyTheOwnerCanChangeTheAllowlist() public {
        vm.prank(RANDOM);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDOM));
        guardHook.setInitializer(RANDOM, true);
    }

    /// @dev The hook registers `beforeInitialize` and nothing else, which is what makes it
    /// inert once a pool exists: no swap, liquidity or donate callback can reach it, so a
    /// broken or abandoned hook can never freeze a graduated pool.
    function test_theHookIsInertOnceThePoolExists() public {
        assertEq(guardHook.getHooksRegistrationBitmap(), 1, "the hook registers more than beforeInitialize");

        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);

        // Nothing below routes through the hook, and all of it still works.
        _swap(_key(), true, 10e18);
        _swap(_key(), false, 1e18);
        _mintPositionTo(RANDOM);
        locker.collect(LAUNCH_ID);
    }

    /// @dev The price band is defence in depth now rather than the defence: with the guard in
    /// place only an allowlisted settler can create the pool at all. It still has to hold, for
    /// the case of a second settler that got there first.
    function test_theBandStillRejectsAMispricedPoolFromAnAllowedInitializer() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        vm.prank(OWNER);
        guardHook.setInitializer(RANDOM, true);

        PoolKey memory key = _key();
        uint160 wrongPrice = _sqrtPriceX96(SEED_TOKEN, SEED_PAIR * 100);
        vm.prank(RANDOM);
        clPoolManager.initialize(key, wrongPrice);

        vm.expectRevert();
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
        assertEq(uint8(core.getLaunchState(LAUNCH_ID)), uint8(ILaunchpadCore.LaunchState.CurveFilled));

        // ... and inside the band it is used as it is.
        vm.prank(OWNER);
        settler.setPoolConfig(2011, 60, guardHook);
        PoolKey memory retryKey = _key();
        uint160 nearTarget = uint160(uint256(_sqrtPriceX96(SEED_TOKEN, SEED_PAIR)) * 10_010 / 10_000);
        vm.prank(RANDOM);
        clPoolManager.initialize(retryKey, nearTarget);

        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
        assertEq(uint8(core.getLaunchState(LAUNCH_ID)), uint8(ILaunchpadCore.LaunchState.Graduated));
    }

    // =====================================================================================
    // Layout canaries
    // =====================================================================================

    /// @dev The settler decodes `creator` and `creatorFeeShareBps` from raw storage words. If
    /// it is ever pointed at a core with a different layout it must fail closed rather than
    /// pay an address it decoded out of garbage.
    function test_layoutCanaryRejectsAMismatchedSettlerWord() public {
        core.seedLaunch(
            LAUNCH_ID, CREATOR, address(launchToken), IERC20(address(pairToken)), RANDOM, SEED_PAIR, CREATOR_BPS
        );
        core.forceState(LAUNCH_ID, ILaunchpadCore.LaunchState.PendingSettlement);
        launchToken.mint(address(settler), SEED_TOKEN);
        pairToken.mint(address(settler), SEED_PAIR);

        vm.prank(address(core));
        vm.expectRevert();
        settler.settle(LAUNCH_ID, SEED_TOKEN);
    }

    function test_layoutCanaryRejectsAMismatchedStateWord() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        launchToken.mint(address(settler), SEED_TOKEN);
        pairToken.mint(address(settler), SEED_PAIR);

        // CurveFilled, not PendingSettlement: only the real `triggerGraduation` ordering
        // produces the state the settler expects to see.
        vm.prank(address(core));
        vm.expectRevert();
        settler.settle(LAUNCH_ID, SEED_TOKEN);
    }

    // =====================================================================================
    // Access control and configuration
    // =====================================================================================

    function test_settleRejectsEveryCallerButTheCore() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        vm.prank(RANDOM);
        vm.expectRevert(InfinitySettler.NotCore.selector);
        settler.settle(LAUNCH_ID, SEED_TOKEN);
    }

    function test_registerRejectsEveryCallerButTheSettler() public {
        // Hoisted: `_key()` reads the settler, and those external calls would otherwise eat
        // the prank before `register` is reached.
        PoolKey memory key = _key();
        vm.prank(RANDOM);
        vm.expectRevert(PositionLocker.NotSettler.selector);
        locker.register(LAUNCH_ID, 1, CREATOR, CREATOR_BPS, key);
    }

    /// @dev A settler that reported a position it never minted here would otherwise point a
    /// launch's fees at someone else's NFT forever.
    function test_registerRejectsAPositionTheLockerDoesNotHold() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);

        // A perfectly ordinary LP opens a position in the graduated pool. It exists, it is
        // in the same pool, and it is not the locker's.
        uint256 outsiderTokenId = _mintPositionTo(RANDOM);
        assertEq(IERC721(address(posm)).ownerOf(outsiderTokenId), RANDOM);

        PoolKey memory key = _key();
        vm.prank(address(settler));
        vm.expectRevert(abi.encodeWithSelector(PositionLocker.PositionNotHeld.selector, outsiderTokenId));
        locker.register(99, outsiderTokenId, CREATOR, CREATOR_BPS, key);
    }

    function test_registerRejectsADuplicateLaunchOrToken() public {
        _prepareLaunch(SEED_TOKEN, SEED_PAIR, CREATOR_BPS);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);

        PoolKey memory key = _key();

        vm.prank(address(settler));
        vm.expectRevert(abi.encodeWithSelector(PositionLocker.AlreadyRegistered.selector, LAUNCH_ID));
        locker.register(LAUNCH_ID, 1, CREATOR, CREATOR_BPS, key);

        vm.prank(address(settler));
        vm.expectRevert(abi.encodeWithSelector(PositionLocker.TokenAlreadyRegistered.selector, uint256(1)));
        locker.register(LAUNCH_ID + 1, 1, CREATOR, CREATOR_BPS, key);
    }

    function test_ownerOnlyConfiguration() public {
        vm.prank(RANDOM);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDOM));
        settler.setPoolConfig(2011, 60, guardHook);

        vm.prank(RANDOM);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDOM));
        locker.setLaunchpadTreasury(RANDOM);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(InfinitySettler.InvalidTier.selector, uint24(3000), int24(0)));
        settler.setPoolConfig(3000, 0, guardHook);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(InfinitySettler.HookHasNoCode.selector, RANDOM));
        settler.setPoolConfig(2011, 60, IHooks(RANDOM));

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(InfinitySettler.InvalidToleranceBps.selector, uint16(10_001)));
        settler.setPriceToleranceBps(10_001);
    }

    function test_theLockerRefusesForeignNFTs() public {
        vm.prank(RANDOM);
        vm.expectRevert(abi.encodeWithSelector(PositionLocker.UnexpectedNFT.selector, RANDOM));
        locker.onERC721Received(RANDOM, RANDOM, 1, "");
    }

    // =====================================================================================
    // Helpers
    // =====================================================================================

    function _prepareLaunch(uint256 seedToken, uint256 seedPair, uint16 creatorBps) internal {
        core.seedLaunch(
            LAUNCH_ID, CREATOR, address(launchToken), IERC20(address(pairToken)), address(settler), seedPair, creatorBps
        );
        launchToken.mint(address(core), seedToken);
        pairToken.mint(address(core), seedPair);
    }

    function _currencies() internal view returns (Currency currency0, Currency currency1) {
        return address(launchToken) < address(pairToken)
            ? (Currency.wrap(address(launchToken)), Currency.wrap(address(pairToken)))
            : (Currency.wrap(address(pairToken)), Currency.wrap(address(launchToken)));
    }

    function _key() internal view returns (PoolKey memory) {
        (Currency currency0, Currency currency1) = _currencies();
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: settler.hooks(),
            poolManager: IPoolManager(address(clPoolManager)),
            fee: settler.lpFee(),
            parameters: settler.poolParameters()
        });
    }

    /// @dev Mirrors the settler's own price derivation so the assertions do not simply
    /// re-run its arithmetic on the numbers it produced.
    function _sqrtPriceX96(uint256 seedToken, uint256 seedPair) internal view returns (uint160) {
        (uint256 amount0, uint256 amount1) =
            address(launchToken) < address(pairToken) ? (seedToken, seedPair) : (seedPair, seedToken);
        return uint160(_sqrt(FullMath.mulDiv(amount1, uint256(1) << 192, amount0)));
    }

    function _assertPoolPriceMatchesRatio(PoolKey memory key, uint256 seedToken, uint256 seedPair) internal view {
        (uint160 sqrtPriceX96,,,) = clPoolManager.getSlot0(key.toId());
        assertGt(sqrtPriceX96, 0, "pool was never initialised");

        (uint256 amount0, uint256 amount1) =
            address(launchToken) < address(pairToken) ? (seedToken, seedPair) : (seedPair, seedToken);

        // price = (sqrtP / 2**96)**2, so amount0 * price should come back to amount1.
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        uint256 implied = FullMath.mulDiv(amount0, priceX96, FixedPoint96.Q96);

        uint256 diff = implied > amount1 ? implied - amount1 : amount1 - implied;
        assertLt(diff * 1e9, amount1, "pool price is not the curve ratio");
    }

    /// @dev A one-directional swap earns fees in one currency only, so a zero credit is a
    /// legitimate outcome rather than something to assert against.
    function _claimIfAny(Currency currency, address who) internal {
        if (locker.owed(currency, who) > 0) locker.claim(currency, who);
    }

    /// @dev Asserts the credit `collect` wrote AND that `claim` delivers exactly it, so the
    /// two halves of the pull cannot drift apart.
    function _assertSplit(Currency currency, uint256 amount, uint16 creatorBps) internal {
        uint256 expectedCreator = amount * creatorBps / 10_000;
        uint256 expectedTreasury = amount - expectedCreator;

        assertEq(locker.owed(currency, CREATOR), expectedCreator, "creator's credit is wrong");
        assertEq(locker.owed(currency, PAD_TREASURY), expectedTreasury, "launchpad's credit is wrong");
        assertEq(locker.totalOwed(currency), amount, "totalOwed does not match what was collected");

        uint256 creatorBefore = IERC20(Currency.unwrap(currency)).balanceOf(CREATOR);
        uint256 treasuryBefore = IERC20(Currency.unwrap(currency)).balanceOf(PAD_TREASURY);
        if (expectedCreator > 0) locker.claim(currency, CREATOR);
        if (expectedTreasury > 0) locker.claim(currency, PAD_TREASURY);

        assertEq(
            IERC20(Currency.unwrap(currency)).balanceOf(CREATOR) - creatorBefore,
            expectedCreator,
            "creator's share is wrong"
        );
        assertEq(
            IERC20(Currency.unwrap(currency)).balanceOf(PAD_TREASURY) - treasuryBefore,
            expectedTreasury,
            "launchpad's share is wrong"
        );
        assertEq(locker.totalOwed(currency), 0, "totalOwed did not clear");
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal {
        MockERC20 tokenIn = MockERC20(Currency.unwrap(zeroForOne ? key.currency0 : key.currency1));
        tokenIn.mint(TRADER, amountIn);
        vm.startPrank(TRADER);
        tokenIn.approve(address(swapRouter), amountIn);
        swapRouter.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
        vm.stopPrank();
    }

    /// @dev Deploy a pair whose ADDRESS ordering is the one the test wants. Which of the two
    /// tokens is currency0 is decided by the addresses the chain hands out, so both cases
    /// have to be constructible.
    function _orderedPair(bool launchIsCurrency0, uint8 launchDecimals, uint8 pairDecimals)
        internal
        returns (MockERC20 launch, MockERC20 pair)
    {
        for (uint256 i; i < 64; ++i) {
            launch = new MockERC20("LAUNCH", "LAUNCH", launchDecimals);
            pair = new MockERC20("PAIR", "PAIR", pairDecimals);
            if ((address(launch) < address(pair)) == launchIsCurrency0) return (launch, pair);
        }
        revert("could not order the pair");
    }

    /// @dev An ordinary full-range mint into the graduated pool, owned by `owner`. Also the
    /// proof that the pool the settler opened is a normal pool anyone can LP into.
    function _mintPositionTo(address owner) internal returns (uint256 tokenId) {
        PoolKey memory key = _key();
        uint256 amount0 = 1e18;
        uint256 amount1 = 1e18;
        MockERC20(Currency.unwrap(key.currency0)).mint(owner, amount0);
        MockERC20(Currency.unwrap(key.currency1)).mint(owner, amount1);

        int24 tickLower = (TickMath.MIN_TICK / key.parameters.getTickSpacing()) * key.parameters.getTickSpacing();
        int24 tickUpper = (TickMath.MAX_TICK / key.parameters.getTickSpacing()) * key.parameters.getTickSpacing();
        (uint160 sqrtPriceX96,,,) = clPoolManager.getSlot0(key.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount0,
            amount1
        );

        tokenId = posm.nextTokenId();
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(key.currency0), address(posm), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(key.currency1), address(posm), type(uint160).max, type(uint48).max);

        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key, tickLower, tickUpper, uint256(liquidity), uint128(amount0), uint128(amount1), owner, bytes("")
            )
        );
        posm.modifyLiquidities(plan.finalizeModifyLiquidityWithSettlePair(key), block.timestamp);
        vm.stopPrank();
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
