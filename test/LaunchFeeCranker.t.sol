// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {CLPositionManager} from "infinity-periphery/src/pool-cl/CLPositionManager.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {ICLPositionDescriptor} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionDescriptor.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";

import {BuybackBurnSink} from "../src/fees/BuybackBurnSink.sol";
import {ChoiceFeeController} from "../src/fees/ChoiceFeeController.sol";
import {IBurnSink} from "../src/interfaces/IBurnSink.sol";
import {IBurnableERC20} from "../src/interfaces/IBurnableERC20.sol";
import {ILaunchpadCore} from "../src/interfaces/ILaunchpadCore.sol";
import {ILaunchPositionLocker} from "../src/interfaces/ILaunchPositionLocker.sol";
import {InfinitySettler} from "../src/launchpad/InfinitySettler.sol";
import {LaunchFeeCranker} from "../src/launchpad/LaunchFeeCranker.sol";
import {LaunchPoolGuardHook} from "../src/launchpad/LaunchPoolGuardHook.sol";
import {PositionLocker} from "../src/launchpad/PositionLocker.sol";
import {MockBurnableERC20} from "./mocks/MockBurnableERC20.sol";
import {MockLaunchpadCore} from "./mocks/MockLaunchpadCore.sol";

/// @notice Plan A6, and the end-to-end half of A5.
///
/// **Nothing is mocked below the launchpad core.** A real settler graduates a real launch onto a
/// real `CLPoolManager` pool, a real `CLPositionManager` holds the seed position, a real
/// `PositionLocker` owns it, real swaps accrue real LP fees, and a real `BuybackBurnSink` sells
/// the launch token into the pool the position manager says it is in and destroys the SPROUT it
/// buys. That matters here more than in the sink's own unit tests: the claim under test is
/// "one call takes accrued fees to burnt supply", and every hand-written stand-in between the
/// two ends is somewhere the claim could be true of the fixture and false of the chain.
///
/// It is also where the sink's `launchId -> PoolKey` lookup meets a locker that was written
/// separately, which is the lockstep A3 cost a graduation to learn - see
/// `test_theLockerInterfaceMatchesTheDeployedLocker`.
contract LaunchFeeCrankerTest is Test, DeployPermit2 {
    using CLPoolParametersHelper for bytes32;

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

    BuybackBurnSink internal sink;
    LaunchFeeCranker internal cranker;

    MockERC20 internal launchToken;
    MockERC20 internal quote; // wINJ, and the sink's QUOTE
    MockBurnableERC20 internal sprout;

    PoolKey internal buybackPool;

    address internal constant OWNER = address(0x71E); // the timelock, on chain
    address internal constant CREATOR = address(0xC12A);
    address internal constant CHOICE_TREASURY = address(0xC401);
    address internal constant OPS = address(0x0B5);
    address internal constant STRANGER = address(0xBEEF);
    address internal constant TRADER = address(0x77AD);

    uint256 internal constant LAUNCH_ID = 42;
    uint16 internal constant CREATOR_BPS = 7000;
    uint16 internal constant FLOOR = 8000;
    uint32 internal constant INTERVAL = 30 minutes;

    uint256 internal constant SEED_TOKEN = 206_900_000e18;
    uint256 internal constant SEED_PAIR = 1_500e18;

    uint24 internal constant FEE = 10_000;
    int24 internal constant SPACING = 200;
    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;

    function setUp() public {
        vault = new Vault();
        clPoolManager = new CLPoolManager(vault);
        vault.registerApp(address(clPoolManager));

        feeController = new ChoiceFeeController(address(clPoolManager), CHOICE_TREASURY, IBurnSink(address(0)));
        clPoolManager.setProtocolFeeController(feeController);

        permit2 = IAllowanceTransfer(deployPermit2());
        posm = new CLPositionManager(
            vault, clPoolManager, permit2, 100_000, ICLPositionDescriptor(address(0)), IWETH9(address(new WETH()))
        );
        swapRouter = new CLPoolManagerRouter(vault, clPoolManager);
        core = new MockLaunchpadCore();

        address predictedSettler = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        locker = new PositionLocker(posm, OPS, OWNER, predictedSettler);
        guardHook = new LaunchPoolGuardHook(OWNER, predictedSettler);
        settler =
            new InfinitySettler(ILaunchpadCore(address(core)), clPoolManager, posm, permit2, locker, guardHook, OWNER);
        assertEq(address(settler), predictedSettler, "settler address prediction is wrong");
        feeController.setLaunchPoolGuardHook(guardHook);

        quote = new MockERC20("Wrapped INJ", "wINJ", 18);
        sprout = new MockBurnableERC20("Sprout", "SPROUT", 18);

        sink = new BuybackBurnSink(
            IBurnableERC20(address(sprout)),
            Currency.wrap(address(quote)),
            IVault(address(vault)),
            posm,
            OPS,
            OWNER,
            FLOOR,
            FLOOR
        );
        cranker = new LaunchFeeCranker(ILaunchPositionLocker(address(locker)), sink);

        buybackPool = _plainKey(quote, sprout);
        _seed(buybackPool, 1_000_000 ether);

        address[] memory lockers = new address[](1);
        lockers[0] = address(locker);
        vm.startPrank(OWNER);
        sink.setBuybackPool(buybackPool);
        sink.setLockers(lockers);
        sink.setGuards(0.0001 ether, 500, INTERVAL);
        // B6: the field that IS the sprout revenue feed. It pointed at the pad treasury for the
        // whole life of the first two sinks, so the burn leg was fed by nothing.
        locker.setLaunchpadTreasury(address(sink));
        vm.stopPrank();

        launchToken = _tokenOrderedAgainstQuote({launchIsCurrency0: true});
    }

    // =====================================================================================
    // A6 - one call, accrued fees to burnt supply
    // =====================================================================================

    /// **The claim this contract exists to make.** Trading a graduated pool accrues LP fees
    /// inside a locked position and nothing else happens. One permissionless call turns that
    /// into destroyed SPROUT.
    function test_oneCallTakesAccruedFeesAllTheWayToBurntSprout() public {
        _graduate();
        _swap(_launchKey(), true, 50_000e18);
        _swap(_launchKey(), false, 10e18);

        uint256 supplyBefore = sprout.totalSupply();

        vm.prank(STRANGER);
        LaunchFeeCranker.Crank memory result = cranker.crank(LAUNCH_ID);

        assertGt(result.collected0 + result.collected1, 0, "the crank collected nothing");
        assertGt(result.claimed0 + result.claimed1, 0, "the crank claimed nothing to the sink");
        assertTrue(result.drove0 && result.drove1, "one of the sink legs did not run");
        assertLt(sprout.totalSupply(), supplyBefore, "no SPROUT was destroyed");

        // 80% burnt, 20% to ops - the immutable floor, measured rather than assumed.
        uint256 burnt = supplyBefore - sprout.totalSupply();
        uint256 toOps = sprout.balanceOf(OPS);
        assertEq(burnt, (burnt + toOps) * FLOOR / 10_000, "the split is not burnBps of what was bought");
    }

    /// 🔑 Both currencies clear in ONE call, and that is the ordering argument in
    /// `crank` made visible. A full-range position earns in both, so a crank that drove the
    /// quote leg first would buy back with the quote it claimed, spend the rate-limit window,
    /// and then leave the conversion's proceeds parked for the next one. Driving the launch
    /// token first makes the conversion's output and the claimed quote one buyback.
    function test_bothLegsClearInOneCallWhicheverWayTheCurrenciesSort() public {
        _assertOneCrankClearsBothLegs();

        // And again with the launch token sorting SECOND, because which leg is currency0 is
        // decided by the addresses the chain hands out and differs per launch.
        setUp();
        launchToken = _tokenOrderedAgainstQuote({launchIsCurrency0: false});
        _assertOneCrankClearsBothLegs();
    }

    function _assertOneCrankClearsBothLegs() internal {
        _graduate();
        _swap(_launchKey(), true, 50_000e18);
        _swap(_launchKey(), false, 10e18);

        cranker.crank(LAUNCH_ID);

        assertEq(launchToken.balanceOf(address(sink)), 0, "the launch-token leg did not clear");
        assertEq(quote.balanceOf(address(sink)), 0, "the quote leg did not clear in the same call");
        assertEq(sprout.balanceOf(address(sink)), 0, "SPROUT was left sitting in the sink");
    }

    /// 🔴 A helper that reverts when there is nothing to do is useless to the keeper it exists
    /// for. `collect` reverts `NothingToCollect` and `claim` reverts `NothingToClaim`, and a
    /// launch that has just been cranked is in exactly that state.
    ///
    /// 🔑 It takes THREE cranks to get there rather than two, and the reason is a property worth
    /// having written down: the sink's conversion is a swap through the graduate's own pool, so
    /// it pays that pool's LP fee - into the very position the crank collects from. The second
    /// crank therefore has something real to take (the fee the first one's conversion generated)
    /// and only its convert leg is idle, rate-limited on the sink's own window. The third finds
    /// the position genuinely empty, and returns.
    function test_crankReturnsCleanlyOnALaunchWithNothingToCollect() public {
        _graduate();
        _swap(_launchKey(), true, 50_000e18);
        cranker.crank(LAUNCH_ID);

        // Second pass: what the first pass's own conversion paid the position.
        LaunchFeeCranker.Crank memory second = cranker.crank(LAUNCH_ID);
        assertGt(second.collected0 + second.collected1, 0, "the conversion paid the position nothing");

        // Third pass, same block: nothing accrued, nothing credited. It must simply return.
        LaunchFeeCranker.Crank memory result = cranker.crank(LAUNCH_ID);
        assertEq(result.collected0, 0, "a spent launch collected something");
        assertEq(result.collected1, 0, "a spent launch collected something");
        assertEq(result.claimed0, 0, "a spent launch claimed something");
        assertEq(result.claimed1, 0, "a spent launch claimed something");
        assertEq(result.tokenId, locker.getPosition(LAUNCH_ID).tokenId, "it lost track of the position");
    }

    /// A launch that graduated and has never been traded is the same shape, from block one.
    function test_crankReturnsCleanlyOnALaunchThatHasNeverTraded() public {
        _graduate();
        LaunchFeeCranker.Crank memory result = cranker.crank(LAUNCH_ID);
        assertEq(result.collected0 + result.collected1, 0, "an untraded pool produced fees");
    }

    /// The one caller error it does report: an id naming no position at all. A keeper walking a
    /// range of ids uses `crankMany`, which catches even this.
    function test_crankRevertsOnAnUnregisteredLaunchButCrankManySkipsIt() public {
        _graduate();
        _swap(_launchKey(), true, 50_000e18);

        vm.expectRevert(abi.encodeWithSelector(LaunchFeeCranker.NotRegistered.selector, uint256(999)));
        cranker.crank(999);

        uint256[] memory ids = new uint256[](3);
        ids[0] = 999;
        ids[1] = LAUNCH_ID;
        ids[2] = 1000;

        uint256 supplyBefore = sprout.totalSupply();
        bool[] memory ok = cranker.crankMany(ids);
        assertFalse(ok[0], "an unregistered launch reported success");
        assertTrue(ok[1], "the real launch was skipped because of its neighbours");
        assertFalse(ok[2], "an unregistered launch reported success");
        assertLt(sprout.totalSupply(), supplyBefore, "the batch burnt nothing");
    }

    /// ⛔ The crank moves the LAUNCHPAD's share and nothing else. The creator's credit is their
    /// money, it is claimable by anyone on their behalf at any time, and this contract must not
    /// be the reason it moves - nor may it end up anywhere near the burn.
    function test_theCreatorsCreditIsUntouched() public {
        _graduate();
        _swap(_launchKey(), true, 50_000e18);
        _swap(_launchKey(), false, 10e18);

        cranker.crank(LAUNCH_ID);

        Currency launchCurrency = Currency.wrap(address(launchToken));
        Currency quoteCurrency = Currency.wrap(address(quote));
        assertGt(
            locker.owed(launchCurrency, CREATOR) + locker.owed(quoteCurrency, CREATOR),
            0,
            "the creator was credited nothing at all - the fixture is not testing this"
        );
        assertEq(locker.owed(launchCurrency, address(sink)), 0, "the launchpad's credit was not paid out");
        assertEq(locker.owed(quoteCurrency, address(sink)), 0, "the launchpad's credit was not paid out");

        // And the creator can still take it, unaffected by the crank having run.
        uint256 owedToCreator = locker.owed(launchCurrency, CREATOR);
        vm.prank(STRANGER);
        locker.claim(launchCurrency, CREATOR);
        assertEq(launchToken.balanceOf(CREATOR), owedToCreator, "the creator's claim was disturbed");
    }

    /// It holds nothing, by construction: `collect` pays the locker, `claim` pays the treasury,
    /// the sink acts on its own balance. There is no owner and no sweep, so a balance stuck here
    /// would be stuck for ever - which is why it must never be on a path.
    function test_theCrankerNeverHoldsABalance() public {
        _graduate();
        _swap(_launchKey(), true, 50_000e18);
        _swap(_launchKey(), false, 10e18);

        cranker.crank(LAUNCH_ID);

        assertEq(launchToken.balanceOf(address(cranker)), 0, "the cranker kept launch tokens");
        assertEq(quote.balanceOf(address(cranker)), 0, "the cranker kept quote");
        assertEq(sprout.balanceOf(address(cranker)), 0, "the cranker kept SPROUT");
    }

    /// It adds no trust: every destination was already fixed, so anybody may choose the moment.
    function test_crankIsPermissionlessAndPaysItsCallerNothing() public {
        _graduate();
        _swap(_launchKey(), true, 50_000e18);

        vm.prank(STRANGER);
        cranker.crank(LAUNCH_ID);

        assertEq(launchToken.balanceOf(STRANGER), 0, "the caller was paid in launch tokens");
        assertEq(quote.balanceOf(STRANGER), 0, "the caller was paid in quote");
        assertEq(sprout.balanceOf(STRANGER), 0, "the caller was paid in SPROUT");
    }

    /// 🔴 B6, as a question anybody can ask. Both lockers pointed `launchpadTreasury` somewhere
    /// that does not burn for the whole life of the first two sinks, and nothing said so.
    function test_feedIsWiredReportsWhetherTheLockerPaysTheSink() public {
        assertTrue(cranker.feedIsWired(), "the fixture is not wired");

        vm.prank(OWNER);
        locker.setLaunchpadTreasury(OPS);
        assertFalse(cranker.feedIsWired(), "an unwired feed reported as wired");
    }

    /// And an unwired feed does not break the crank - it collects and pays whatever the locker
    /// currently names, because redirecting somebody's money would be the worse failure.
    function test_anUnwiredFeedStillCollectsAndPaysTheNamedTreasury() public {
        _graduate();
        _swap(_launchKey(), true, 50_000e18);

        vm.prank(OWNER);
        locker.setLaunchpadTreasury(OPS);

        uint256 supplyBefore = sprout.totalSupply();
        LaunchFeeCranker.Crank memory result = cranker.crank(LAUNCH_ID);

        assertGt(result.claimed0 + result.claimed1, 0, "nothing was paid out at all");
        assertGt(launchToken.balanceOf(OPS) + quote.balanceOf(OPS), 0, "the named treasury was not paid");
        assertEq(sprout.totalSupply(), supplyBefore, "an unwired feed still burnt something");
    }

    /// ⚠️ D28's open edge, reached through the crank. A launch paired against an asset that is
    /// not the sink's `QUOTE` has a pool the sink cannot convert through, and `convert` says so
    /// by reverting. That must not take the collect and the claim with it: the fees still leave
    /// the position and still reach the treasury, they simply wait there for a route.
    function test_aLaunchPairedAgainstAnotherAssetStillCollectsAndClaims() public {
        MockERC20 otherQuote = new MockERC20("Sai", "SAI", 18);
        launchToken = _tokenOrderedAgainst(otherQuote, true);
        _graduateAgainst(otherQuote);
        _swap(_launchKeyAgainst(otherQuote), true, 50_000e18);
        _swap(_launchKeyAgainst(otherQuote), false, 10e18);

        uint256 supplyBefore = sprout.totalSupply();
        LaunchFeeCranker.Crank memory result = cranker.crank(LAUNCH_ID);

        assertGt(result.collected0 + result.collected1, 0, "the collect was taken down with the convert");
        assertGt(result.claimed0 + result.claimed1, 0, "the claim was taken down with the convert");
        assertFalse(result.drove0 && result.drove1, "a leg with no route reported that it drove");
        assertGt(launchToken.balanceOf(address(sink)) + otherQuote.balanceOf(address(sink)), 0, "nothing arrived");
        assertEq(sprout.totalSupply(), supplyBefore, "something burnt through a pool that cannot exist");
    }

    /// 🔫 **The same launch, after the second leg exists — the whole of A2, end to end.**
    ///
    /// Nothing about the launch changes: the same SAI-paired graduate, the same real settler,
    /// the same real `PositionLocker` and the same real `CLPositionManager`. One owner call
    /// registers the pool SAI reaches wINJ through, and the identical crank now takes BOTH
    /// halves of the fee — the launch token through two legs, and the SAI half through one —
    /// all the way to destroyed SPROUT.
    function test_aLaunchPairedAgainstAnotherAssetBurnsOnceTheSecondLegIsRegistered() public {
        MockERC20 otherQuote = new MockERC20("Sai", "SAI", 18);
        launchToken = _tokenOrderedAgainst(otherQuote, true);
        _graduateAgainst(otherQuote);
        _swap(_launchKeyAgainst(otherQuote), true, 50_000e18);
        _swap(_launchKeyAgainst(otherQuote), false, 10e18);

        // 🔴 An ORDINARY pool with no hook — which is exactly why it has to be registered. A
        // graduation pool's key is un-createable by anyone but an allowlisted settler, so A5
        // could derive one safely; anybody can open this one, at any price they choose.
        PoolKey memory hop = _plainKey(otherQuote, quote);
        _seed(hop, 500_000 ether);
        vm.prank(OWNER);
        sink.setQuoteRoute(Currency.wrap(address(otherQuote)), hop);

        uint256 supplyBefore = sprout.totalSupply();

        vm.prank(STRANGER);
        LaunchFeeCranker.Crank memory result = cranker.crank(LAUNCH_ID);

        assertGt(result.collected0 + result.collected1, 0, "nothing was collected");
        assertGt(result.claimed0 + result.claimed1, 0, "nothing was claimed");
        assertTrue(result.drove0 && result.drove1, "a leg was still refused after the route existed");
        assertLt(supplyBefore - sprout.totalSupply(), supplyBefore, "sanity");
        assertGt(supplyBefore - sprout.totalSupply(), 0, "a SAI-paired graduate still burnt nothing");
        assertGt(sprout.balanceOf(OPS), 0, "the ops share never reached the treasury");
    }

    /// The launchpad's own token is a launch like any other, and its LP fees are burn revenue
    /// with no swap in the way: the sink's `BURN_TOKEN` arm splits and destroys the balance.
    function test_aSproutPairedLaunchBurnsItsOwnLegDirectly() public {
        launchToken = MockERC20(address(sprout));
        _graduate();
        _swap(_launchKey(), true, 50_000e18);
        _swap(_launchKey(), false, 10e18);

        uint256 supplyBefore = sprout.totalSupply();
        LaunchFeeCranker.Crank memory result = cranker.crank(LAUNCH_ID);

        assertTrue(result.drove0 && result.drove1, "one of the legs did not run");
        assertLt(sprout.totalSupply(), supplyBefore, "the burn token's own fee leg was not destroyed");
        assertEq(sprout.balanceOf(address(sink)), 0, "SPROUT was left sitting in the sink");
    }

    // =====================================================================================
    // A5 - against the real locker and the real position manager
    // =====================================================================================

    /// The sink is never told a launch's pool. It reads the LOCKED POSITION and takes the key
    /// that position is in - proven here against the key the settler actually opened, by id.
    function test_theSinkFindsTheRealPoolOfARealGraduate() public {
        _graduate();

        BuybackBurnSink.Route memory route = sink.conversionRoute(Currency.wrap(address(launchToken)), LAUNCH_ID);
        assertEq(route.legs, 1, "a wINJ-paired graduate needs exactly one leg");
        assertEq(PoolId.unwrap(route.first.toId()), PoolId.unwrap(_launchKey().toId()), "that is not the graduated pool");
        assertEq(route.firstZeroForOne, address(launchToken) < address(quote), "the sell direction is wrong");

        (PoolKey memory unfiltered, address answering) = sink.launchPool(LAUNCH_ID);
        assertEq(PoolId.unwrap(unfiltered.toId()), PoolId.unwrap(_launchKey().toId()), "launchPool disagrees");
        assertEq(answering, address(locker), "the wrong locker answered");
    }

    /// 🔴 **The lockstep check.** `ILaunchPositionLocker` is a hand-written copy of part of
    /// `PositionLocker`'s ABI, and a copy of an ABI is exactly what wedged a graduation on
    /// 2026-09-06 - the settler's locker had gained an argument, so its `register` had a
    /// different selector, and the call reverted with EMPTY returndata after passing every gate.
    ///
    /// This calls a REAL `PositionLocker` through the interface, every function of it. A drifted
    /// selector fails to compile or reverts here, where somebody is looking, rather than inside
    /// a conversion that then parks with nothing to explain it.
    function test_theLockerInterfaceMatchesTheDeployedLocker() public {
        _graduate();
        _swap(_launchKey(), true, 50_000e18);

        ILaunchPositionLocker viaInterface = ILaunchPositionLocker(address(locker));

        assertEq(address(viaInterface.POSITION_MANAGER()), address(posm), "POSITION_MANAGER drifted");
        assertEq(viaInterface.launchpadTreasury(), address(sink), "launchpadTreasury drifted");

        ILaunchPositionLocker.LockedPosition memory position = viaInterface.getPosition(LAUNCH_ID);
        assertEq(position.tokenId, locker.getPosition(LAUNCH_ID).tokenId, "getPosition decodes differently");
        assertEq(position.creator, CREATOR, "getPosition decodes differently");
        assertEq(position.creatorBps, CREATOR_BPS, "getPosition decodes differently");

        (uint256 amount0, uint256 amount1) = viaInterface.collect(LAUNCH_ID);
        assertGt(amount0 + amount1, 0, "collect through the interface returned nothing");

        Currency credited = Currency.wrap(
            amount0 > 0 ? Currency.unwrap(_launchKey().currency0) : Currency.unwrap(_launchKey().currency1)
        );
        uint256 paid = viaInterface.claim(credited, address(sink));
        assertGt(paid, 0, "claim through the interface paid nothing");
    }

    // =====================================================================================
    // Wiring
    // =====================================================================================

    function test_theCrankerReadsItsWholeConfigurationOffItsTwoArguments() public view {
        assertEq(address(cranker.LOCKER()), address(locker), "wrong locker");
        assertEq(address(cranker.SINK()), address(sink), "wrong sink");
        assertEq(address(cranker.POSITION_MANAGER()), address(posm), "position manager was not read off the locker");
        assertEq(Currency.unwrap(cranker.QUOTE()), address(quote), "quote was not read off the sink");
        assertEq(cranker.BURN_TOKEN(), address(sprout), "burn token was not read off the sink");
    }

    function test_theCrankerRefusesAZeroArgument() public {
        vm.expectRevert(LaunchFeeCranker.ZeroAddress.selector);
        new LaunchFeeCranker(ILaunchPositionLocker(address(0)), sink);

        vm.expectRevert(LaunchFeeCranker.ZeroAddress.selector);
        new LaunchFeeCranker(ILaunchPositionLocker(address(locker)), BuybackBurnSink(payable(address(0))));
    }

    function test_launchPoolViewAnswersForAGraduateAndNotForAnythingElse() public {
        (uint256 missing,) = cranker.launchPool(LAUNCH_ID);
        assertEq(missing, 0, "an ungraduated launch reported a position");

        _graduate();
        (uint256 tokenId, PoolKey memory key) = cranker.launchPool(LAUNCH_ID);
        assertEq(tokenId, locker.getPosition(LAUNCH_ID).tokenId, "the wrong position");
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(_launchKey().toId()), "the wrong pool");
    }

    // =====================================================================================
    // Helpers
    // =====================================================================================

    function _graduate() internal {
        _graduateAgainst(quote);
    }

    function _graduateAgainst(MockERC20 pair) internal {
        core.seedLaunch(
            LAUNCH_ID, CREATOR, address(launchToken), IERC20(address(pair)), address(settler), SEED_PAIR, CREATOR_BPS
        );
        launchToken.mint(address(core), SEED_TOKEN);
        pair.mint(address(core), SEED_PAIR);
        core.triggerGraduation(LAUNCH_ID, SEED_TOKEN);
    }

    function _launchKey() internal view returns (PoolKey memory) {
        return _launchKeyAgainst(quote);
    }

    function _launchKeyAgainst(MockERC20 pair) internal view returns (PoolKey memory) {
        (address c0, address c1) = address(launchToken) < address(pair)
            ? (address(launchToken), address(pair))
            : (address(pair), address(launchToken));
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: settler.hooks(),
            poolManager: IPoolManager(address(clPoolManager)),
            fee: settler.lpFee(),
            parameters: settler.poolParameters()
        });
    }

    /// @dev The buyback pool. Not a graduation pool - SPROUT has not graduated in this fixture -
    /// so it carries no hook and is opened directly.
    function _plainKey(MockERC20 a, MockERC20 b) internal view returns (PoolKey memory) {
        (address c0, address c1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(clPoolManager)),
            fee: FEE,
            parameters: bytes32(0).setTickSpacing(SPACING)
        });
    }

    function _seed(PoolKey memory key, uint256 amount) internal {
        clPoolManager.initialize(key, SQRT_1_1);
        MockERC20(Currency.unwrap(key.currency0)).mint(address(this), amount);
        MockERC20(Currency.unwrap(key.currency1)).mint(address(this), amount);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(swapRouter), type(uint256).max);
        swapRouter.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -887200, tickUpper: 887200, liquidityDelta: int256(amount / 2), salt: bytes32(0)
            }),
            ""
        );
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

    /// @dev Which of the two tokens is `currency0` is decided by the addresses the chain hands
    /// out, and the crank's leg ordering has to be right for both.
    function _tokenOrderedAgainstQuote(bool launchIsCurrency0) internal returns (MockERC20) {
        return _tokenOrderedAgainst(quote, launchIsCurrency0);
    }

    function _tokenOrderedAgainst(MockERC20 pair, bool launchIsCurrency0) internal returns (MockERC20 token) {
        for (uint256 i; i < 128; ++i) {
            token = new MockERC20("LAUNCH", "LAUNCH", 18);
            if ((address(token) < address(pair)) == launchIsCurrency0) return token;
        }
        revert("could not order the pair");
    }
}
