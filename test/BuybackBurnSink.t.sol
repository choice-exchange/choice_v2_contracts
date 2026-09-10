// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";

import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

import {BuybackBurnSink} from "../src/fees/BuybackBurnSink.sol";
import {LaunchPoolGuardHook} from "../src/launchpad/LaunchPoolGuardHook.sol";
import {IBurnableERC20} from "../src/interfaces/IBurnableERC20.sol";
import {MockBurnableERC20} from "./mocks/MockBurnableERC20.sol";
import {MockPositionLocker} from "./mocks/MockPositionLocker.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";

/// A real `Vault` + `CLPoolManager` with a real seeded pool. The sink's whole job is to swap
/// and burn, so neither the swap nor the burn is mocked: the pool is the upstream one and the
/// burn really reduces `totalSupply`, which is what the assertions read.
contract BuybackBurnSinkTest is Test {
    using CLPoolParametersHelper for bytes32;

    address internal constant TIMELOCK = address(0x71E);
    address internal constant TREASURY = address(0x7EA);
    address internal constant STRANGER = address(0xBEEF);

    uint24 internal constant FEE = 10_000; // the launchpad's 1% graduation tier
    int24 internal constant SPACING = 200;
    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;

    uint16 internal constant FLOOR = 8000;
    uint32 internal constant INTERVAL = 30 minutes;

    /// The launch each fixture token graduated as. Arbitrary numbers: the sink treats a launch
    /// id as a lookup key and never as a permission, which is what most of these tests are about.
    uint256 internal constant MEME_LAUNCH = 20;
    uint256 internal constant MEME2_LAUNCH = 21;
    /// A launch that graduated on an EARLIER fee tier - testnet's launch 14, in miniature. Under
    /// A4's derived tier this one was unreachable while the current tier was installed, and its
    /// revenue parked; it is the regression this file exists to keep closed.
    uint256 internal constant STRAGGLER_LAUNCH = 14;
    /// The tier that launch graduated on, which is NOT the one anything graduates on today.
    uint24 internal constant OLD_FEE = 6722;
    /// A launch paired against a quote asset that is not `QUOTE`. Testnet's launch 19.
    uint256 internal constant SAI_LAUNCH = 19;

    Vault internal vault;
    CLPoolManager internal manager;
    CLPoolManagerRouter internal seeder;

    MockERC20 internal quote; // wINJ
    MockBurnableERC20 internal burnToken;
    MockERC20 internal stray; // a currency with no pool anywhere

    /// A launch token that is NOT the burn token, which is the case §9.0's walk could not
    /// reach: its test launch token WAS the burn token, so it hit the `BURN_TOKEN` arm and settled.
    MockERC20 internal meme;
    /// A second one, to show that one launch token's rate-limit window is its own.
    MockERC20 internal meme2;

    /// A launch token whose pool sits on the fee tier launches graduated on BEFORE A0 - the
    /// straggler the derived tier could not reach.
    MockERC20 internal straggler;

    /// A second quote asset - testnet's SAI - and a launch paired against it. This is testnet
    /// launch 19 in miniature: it graduates fine, its fees collect and claim fine, and until a
    /// route exists the sink can do nothing with either half of them.
    MockERC20 internal sai;
    MockERC20 internal pre2e;

    /// The real guard hook. It no longer gates the conversion (a locked position does), but it
    /// is still what a graduation pool is keyed to, so the fixture pools carry it.
    LaunchPoolGuardHook internal guardHook;

    /// Where the sink looks a launch's real pool key up. Stand-ins here; the end-to-end proof
    /// against a real `PositionLocker` and a real `CLPositionManager` is in
    /// `LaunchFeeCranker.t.sol`.
    MockPositionManager internal posm;
    MockPositionLocker internal locker;

    BuybackBurnSink internal sink;
    PoolKey internal pool;
    PoolKey internal memePool;
    PoolKey internal meme2Pool;
    PoolKey internal stragglerPool;
    /// The SAI-paired graduate's own pool - guard-hooked, like every graduation pool.
    PoolKey internal saiLaunchPool;
    /// 🔴 And the second leg: an ORDINARY SAI/wINJ pool with NO HOOK. That is the whole reason
    /// this one has to be registered rather than derived - anyone can open a hookless pool at
    /// any key, at any price, so a derived second leg would name a pool an attacker can create.
    PoolKey internal saiQuotePool;

    function setUp() public {
        vault = new Vault();
        manager = new CLPoolManager(vault);
        vault.registerApp(address(manager));
        seeder = new CLPoolManagerRouter(vault, manager);

        quote = new MockERC20("Wrapped INJ", "wINJ", 18);
        burnToken = new MockBurnableERC20("Burn Token", "BURN", 18);
        stray = new MockERC20("Stray", "STRAY", 18);
        meme = new MockERC20("Launch", "LAUNCH", 18);
        meme2 = new MockERC20("Launch Two", "LAUNCH2", 18);
        straggler = new MockERC20("Old Launch", "OLD", 18);
        sai = new MockERC20("SAI", "SAI", 18);
        pre2e = new MockERC20("SAI-paired Launch", "PRE2E", 18);
        guardHook = new LaunchPoolGuardHook(address(this), address(this));

        posm = new MockPositionManager();
        locker = new MockPositionLocker(ICLPositionManager(address(posm)), address(0xDADD));

        sink = _freshSink();

        pool = _key(quote, burnToken, FEE);
        _seed(pool, 1_000_000 ether);

        // The graduation pool of a launch that is not the burn token: same 1% tier, same spacing, keyed
        // to the guard hook. Deliberately thinner than the buyback pool - a graduate's seed is
        // whatever its curve filled, not a market-made book.
        memePool = _graduationKey(meme, FEE);
        _seed(memePool, 100_000 ether);
        meme2Pool = _graduationKey(meme2, FEE);
        _seed(meme2Pool, 100_000 ether);

        // And one on the tier launches graduated on BEFORE A0. Same hook, same spacing, one fee
        // field different - which is all it took to make A4's derived key miss it.
        stragglerPool = _graduationKey(straggler, OLD_FEE);
        _seed(stragglerPool, 100_000 ether);

        // Launch 19's shape: the graduate trades against SAI, and SAI reaches wINJ through an
        // ordinary pool nobody's settler opened.
        saiLaunchPool = _pairKey(pre2e, sai, FEE);
        _seed(saiLaunchPool, 100_000 ether);
        saiQuotePool = _key(sai, quote, FEE);
        _seed(saiQuotePool, 500_000 ether);

        // The chain a launch id walks: locker says which position, position manager says which
        // pool. Registered here rather than derived, which is the whole of A5.
        _lock(MEME_LAUNCH, 1, memePool);
        _lock(MEME2_LAUNCH, 2, meme2Pool);
        _lock(STRAGGLER_LAUNCH, 3, stragglerPool);
        _lock(SAI_LAUNCH, 4, saiLaunchPool);

        vm.startPrank(TIMELOCK);
        sink.setBuybackPool(pool);
        sink.setLockers(_one(address(locker)));
        // 1 wINJ minimum, 500 bps of sqrt-price headroom, one window per half hour. The rate
        // limit is not optional any more - `setGuards` refuses zero - so the fixture carries a
        // production-shaped value and tests that want a second buyback warp past it.
        sink.setGuards(1 ether, 500, INTERVAL);
        vm.stopPrank();
    }

    // ── the reason this contract exists ───────────────────────────────────

    /// The whole loop, end to end: revenue in quote becomes the burn token, 80% of it is destroyed for
    /// real, and the ops share reaches the treasury.
    function test_revenueIsBoughtBackAndEightyPercentIsDestroyed() public {
        uint256 supplyBefore = burnToken.totalSupply();
        quote.mint(address(sink), 100 ether);

        sink.burn(Currency.wrap(address(quote)), 100 ether);

        uint256 burnt = supplyBefore - burnToken.totalSupply();
        uint256 toTreasury = burnToken.balanceOf(TREASURY);
        uint256 bought = burnt + toTreasury;

        assertGt(bought, 0, "nothing was bought");
        assertEq(burnt, bought * FLOOR / 10_000, "burn share is not burnBps of what was bought");
        assertEq(toTreasury, bought - burnt, "treasury did not get the remainder");
        assertEq(burnToken.balanceOf(address(sink)), 0, "burn tokens were left sitting in the sink");
        assertEq(quote.balanceOf(address(sink)), 0, "quote was left unspent");
    }

    /// The normalise leg (A4), which is the arm §9.0's walk could never reach: its launch token
    /// WAS the burn token, so it settled directly. A launch token that is not the burn token used to
    /// park for ever; now it is sold for wINJ against its OWN graduation pool, and the proceeds
    /// go straight on to buy the burn token and destroy it - all in the one call `harvest` makes.
    function test_aLaunchTokenIsConvertedBoughtBackAndBurnt() public {
        uint256 supplyBefore = burnToken.totalSupply();
        meme.mint(address(sink), 100 ether);

        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);

        uint256 burnt = supplyBefore - burnToken.totalSupply();
        uint256 toTreasury = burnToken.balanceOf(TREASURY);

        assertGt(burnt, 0, "the launch token parked instead of burning");
        assertEq(burnt, (burnt + toTreasury) * FLOOR / 10_000, "burn share is not burnBps of what was bought");
        assertEq(meme.balanceOf(address(sink)), 0, "the launch token was not fully converted");
        assertEq(quote.balanceOf(address(sink)), 0, "the wINJ it converted to was not spent");
        assertEq(burnToken.balanceOf(address(sink)), 0, "burn tokens were left sitting in the sink");
    }

    /// `burn` is what `ChoiceFeeController.harvest` calls after transferring. If it can revert,
    /// a launch token bricks harvesting for that currency - so it must not, whether or not a pool
    /// for it exists anywhere.
    ///
    /// 🔴 A5 changed what this arm DOES, and the change is deliberate. `burn` takes a currency and
    /// an amount and has nowhere to carry a launch id, so it can no longer look a launch's pool
    /// up; it parks with reason 6 - "somebody has to pass a launch id" - which a dashboard can
    /// tell apart from a currency that has no pool at all. Under D30 no fee controller points at
    /// this sink, so nothing calls `burn` automatically: launch-token revenue arrives as a bare
    /// transfer from `PositionLocker.claim` and `LaunchFeeCranker` is what moves it on.
    function test_burnParksALaunchTokenBecauseItCarriesNoLaunchId() public {
        meme.mint(address(sink), 100 ether);

        vm.expectEmit(true, false, false, true, address(sink));
        emit BuybackBurnSink.Parked(Currency.wrap(address(meme)), 100 ether, 6);
        sink.burn(Currency.wrap(address(meme)), 100 ether);

        assertEq(meme.balanceOf(address(sink)), 100 ether, "the tranche should be held, not moved");
        assertEq(meme.balanceOf(TREASURY), 0, "ops must not receive what the burn was entitled to");

        // And it is not stranded: the hinted call picks up exactly what `burn` parked.
        uint256 supplyBefore = burnToken.totalSupply();
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);
        assertEq(meme.balanceOf(address(sink)), 0, "the parked tranche was not picked up");
        assertLt(burnToken.totalSupply(), supplyBefore, "the parked tranche did not reach the burn");
    }

    /// And a sink with no lockers installed yet cannot resolve any hint - it must park rather
    /// than revert, or wiring it in the wrong order would brick harvests until somebody noticed.
    function test_burnDoesNotRevertBeforeAnyLockerIsConfigured() public {
        BuybackBurnSink fresh = _freshSink();
        meme.mint(address(fresh), 100 ether);

        vm.expectEmit(true, false, false, true, address(fresh));
        emit BuybackBurnSink.Parked(Currency.wrap(address(meme)), 100 ether, 6);
        fresh.burn(Currency.wrap(address(meme)), 100 ether);

        assertEq(meme.balanceOf(address(fresh)), 100 ether, "funds should be held until a locker exists");
    }

    /// An unconfigured sink must also park rather than revert, or wiring it in the wrong order
    /// would brick harvests until someone noticed.
    function test_burnDoesNotRevertBeforeAPoolIsConfigured() public {
        BuybackBurnSink fresh = _freshSink();
        quote.mint(address(fresh), 100 ether);

        fresh.burn(Currency.wrap(address(quote)), 100 ether);

        assertEq(quote.balanceOf(address(fresh)), 100 ether, "funds should be held until a pool exists");
    }

    // ── the guards ────────────────────────────────────────────────────────

    /// The impact bound is a price limit on the swap, so an oversized tranche fills PARTIALLY
    /// and the remainder stays for next time. A `minAmountOut` check would have had to revert.
    function test_impactLimitCapsTheFillAndLeavesTheRestForNextTime() public {
        vm.prank(TIMELOCK);
        sink.setGuards(1 ether, 50, INTERVAL); // 50 bps of sqrt price: very tight

        quote.mint(address(sink), 500_000 ether);
        sink.burn(Currency.wrap(address(quote)), 500_000 ether);

        uint256 leftover = quote.balanceOf(address(sink));
        assertGt(leftover, 0, "the limit did not bind - nothing was left over");
        assertLt(leftover, 500_000 ether, "the limit bound so hard that nothing traded");
        assertGt(burnToken.balanceOf(TREASURY), 0, "a partial fill still has to settle its burn");
    }

    function test_belowTheMinimumRevenueAccumulatesInsteadOfTrading() public {
        quote.mint(address(sink), 0.5 ether); // under the 1 ether floor

        sink.burn(Currency.wrap(address(quote)), 0.5 ether);

        assertEq(quote.balanceOf(address(sink)), 0.5 ether, "dust should accumulate");
        assertEq(burnToken.balanceOf(TREASURY), 0, "nothing should have been bought");
    }

    /// D20: without a rate limit a searcher picks the moment of every buyback. With one, a
    /// second call in the same window parks instead of trading.
    function test_rateLimitParksASecondBuybackInTheSameWindow() public {
        vm.prank(TIMELOCK);
        sink.setGuards(1 ether, 500, 1 hours);

        quote.mint(address(sink), 100 ether);
        sink.burn(Currency.wrap(address(quote)), 100 ether);
        uint256 afterFirst = burnToken.balanceOf(TREASURY);
        assertGt(afterFirst, 0, "the first buyback should have run");

        quote.mint(address(sink), 100 ether);
        sink.burn(Currency.wrap(address(quote)), 100 ether);
        assertEq(burnToken.balanceOf(TREASURY), afterFirst, "the second buyback should have been rate-limited");
        assertEq(quote.balanceOf(address(sink)), 100 ether, "the parked tranche should still be here");

        vm.warp(block.timestamp + 1 hours);
        sink.buyback();
        assertGt(burnToken.balanceOf(TREASURY), afterFirst, "the window reopened and it still did not run");
        assertEq(quote.balanceOf(address(sink)), 0, "the parked tranche should have been spent");
    }

    function test_canBuybackTracksTheGuards() public {
        vm.prank(TIMELOCK);
        sink.setGuards(1 ether, 500, 1 hours);

        assertFalse(sink.canBuyback(), "empty sink should not claim it can trade");
        quote.mint(address(sink), 100 ether);
        assertTrue(sink.canBuyback(), "funded and unrestricted, it should be able to trade");

        sink.buyback();
        quote.mint(address(sink), 100 ether);
        assertFalse(sink.canBuyback(), "inside the interval it should report false");
    }

    // ── the normalise leg (A4) and the D32 hold allowlist ─────────────────

    /// The sink is never TOLD a launch's pool: it derives the key from the tier every graduation
    /// is keyed to, which is what makes one timelock call cover every launch, past and future.
    /// The derivation is checked here against the pool that actually exists, by its id.
    /// A5. The sink no longer reconstructs a graduation key from a stored tier - it reads the
    /// launch's LOCKED POSITION and takes the key that position is actually in. Checked here
    /// against the pool that exists, by its id.
    function test_theConversionPoolIsReadOffTheLockedPosition() public view {
        BuybackBurnSink.Route memory route = sink.conversionRoute(Currency.wrap(address(meme)), MEME_LAUNCH);

        assertEq(route.legs, 1, "a QUOTE-paired graduate needs exactly one leg");
        assertEq(PoolId.unwrap(route.first.toId()), PoolId.unwrap(memePool.toId()), "that is not the graduated pool");
        assertEq(route.firstZeroForOne, address(meme) < address(quote), "the sell direction is wrong");
    }

    /// 🔴 **The regression A5 exists for.** A launch that graduated on an earlier fee tier used
    /// to be unreachable: the sink derived a key on the CURRENT tier, no pool existed there, and
    /// the tranche parked with nothing to look at until somebody pointed the tier back. On
    /// testnet that was launch 14 - a 6722 pool while 10000 was installed - and its revenue sat.
    ///
    /// Nothing is installed here at all. The launch's own position names its own pool, whatever
    /// tier it happens to be on, so the tranche converts.
    function test_aLaunchThatGraduatedOnAnotherTierStillConverts() public {
        assertTrue(stragglerPool.fee != memePool.fee, "the fixture is not testing two tiers");

        uint256 supplyBefore = burnToken.totalSupply();
        straggler.mint(address(sink), 100 ether);

        BuybackBurnSink.Route memory route = sink.conversionRoute(Currency.wrap(address(straggler)), STRAGGLER_LAUNCH);
        assertEq(route.first.fee, OLD_FEE, "the sink did not follow the launch onto its own tier");

        sink.convert(Currency.wrap(address(straggler)), STRAGGLER_LAUNCH);

        assertEq(straggler.balanceOf(address(sink)), 0, "the straggler did not convert");
        assertLt(burnToken.totalSupply(), supplyBefore, "the straggler's revenue never reached the burn");
    }

    /// 🔑 **Why a launch id can be taken from anybody.** It selects a pool; the pool is then
    /// required to trade exactly the currency being sold against `QUOTE`. Naming somebody else's
    /// launch names a pool that holds other currencies, so there is no id that routes this swap
    /// somewhere the caller chose.
    function test_aLaunchIdThatNamesAnotherLaunchesPoolIsRefused() public {
        meme.mint(address(sink), 100 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackBurnSink.LaunchDoesNotTrade.selector, MEME2_LAUNCH, Currency.wrap(address(meme))
            )
        );
        sink.convert(Currency.wrap(address(meme)), MEME2_LAUNCH);

        assertEq(meme.balanceOf(address(sink)), 100 ether, "a refused hint must not move anything");
    }

    /// And an id nobody has registered resolves to no position at all.
    function test_anUnregisteredLaunchIdIsRefused() public {
        meme.mint(address(sink), 100 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackBurnSink.LaunchDoesNotTrade.selector, uint256(999), Currency.wrap(address(meme))
            )
        );
        sink.convert(Currency.wrap(address(meme)), 999);
    }

    /// 🔴 The locker set is the trust anchor, so a locker that is not in it answers nothing -
    /// even when it holds a position for the launch and even when that position's pool would
    /// have passed the currency check. This is the check that stops "point at any contract that
    /// implements two views" from being a way to aim a conversion.
    function test_aPositionInALockerOutsideTheSetIsIgnored() public {
        MockPositionLocker rogue = new MockPositionLocker(ICLPositionManager(address(posm)), address(0xBAD));
        rogue.register(777, 1); // tokenId 1 IS meme's real graduation pool

        meme.mint(address(sink), 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackBurnSink.LaunchDoesNotTrade.selector, uint256(777), Currency.wrap(address(meme))
            )
        );
        sink.convert(Currency.wrap(address(meme)), 777);

        // Installed, the same call goes through - so what changed was the designation, not the
        // position, and the designation is the timelock's.
        address[] memory both = new address[](2);
        both[0] = address(locker);
        both[1] = address(rogue);
        vm.prank(TIMELOCK);
        sink.setLockers(both);

        sink.convert(Currency.wrap(address(meme)), 777);
        assertEq(meme.balanceOf(address(sink)), 0, "installing the locker did not open the route");
    }

    /// ⚠️ D28's open edge, stated as a test so nobody rediscovers it as a bug. A launch paired
    /// against something that is not this sink's `QUOTE` has a pool the sink cannot use: it would
    /// come out holding a third currency with no second leg to wINJ. It is REFUSED, loudly,
    /// rather than routed or silently parked.
    function test_aLaunchPairedAgainstAnotherQuoteAssetIsRefused() public {
        MockERC20 otherQuote = new MockERC20("Sai", "SAI", 18);
        MockERC20 token = new MockERC20("Other", "OTHER", 18);
        PoolKey memory otherPool = _pairKey(token, otherQuote, FEE);
        _seed(otherPool, 100_000 ether);
        _lock(30, 9, otherPool);

        token.mint(address(sink), 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackBurnSink.LaunchDoesNotTrade.selector, uint256(30), Currency.wrap(address(token))
            )
        );
        sink.convert(Currency.wrap(address(token)), 30);
    }

    /// D32. Convert is the default so the burn rate holds; a designated token accumulates
    /// instead. This is the old `PARK_NO_ROUTE` accident promoted to a policy that says so.
    function test_aLaunchTokenOnTheHoldAllowlistParksInsteadOfConverting() public {
        vm.prank(TIMELOCK);
        sink.setHold(Currency.wrap(address(meme)), true);

        uint256 supplyBefore = burnToken.totalSupply();
        meme.mint(address(sink), 100 ether);

        vm.expectEmit(true, false, false, true, address(sink));
        emit BuybackBurnSink.Parked(Currency.wrap(address(meme)), 100 ether, 5);
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);

        assertEq(meme.balanceOf(address(sink)), 100 ether, "a held token should accumulate");
        assertEq(burnToken.totalSupply(), supplyBefore, "a held token must not reach the burn");

        // A held token reports the POLICY through `burn` too, rather than the missing hint.
        vm.expectEmit(true, false, false, true, address(sink));
        emit BuybackBurnSink.Parked(Currency.wrap(address(meme)), 100 ether, 5);
        sink.burn(Currency.wrap(address(meme)), 100 ether);

        // And it is a policy, not a one-way door: lifting the designation converts it.
        vm.prank(TIMELOCK);
        sink.setHold(Currency.wrap(address(meme)), false);
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);
        assertLt(burnToken.totalSupply(), supplyBefore, "lifting the hold did not release the conversion");
    }

    /// The impact bound is one price limit serving both legs, so an oversized conversion fills
    /// PARTIALLY against it and the rest stays here for the next window. It does NOT revert -
    /// `burn` cannot - and it does not hand the tranche to anybody either.
    function test_aConversionThatWouldBreachTheImpactBoundParksTheRemainder() public {
        vm.prank(TIMELOCK);
        sink.setGuards(1 ether, 50, INTERVAL); // 50 bps of sqrt price: very tight

        meme.mint(address(sink), 500_000 ether);
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);

        uint256 leftover = meme.balanceOf(address(sink));
        assertGt(leftover, 0, "the bound did not bind - the whole tranche converted");
        assertLt(leftover, 500_000 ether, "the bound bound so hard that nothing converted");
        assertEq(meme.balanceOf(TREASURY), 0, "the remainder must stay here, not go to ops");
        assertGt(burnToken.balanceOf(TREASURY), 0, "a partial conversion still has to reach the burn");
    }

    /// And the harder case the bound can produce: a pool already sitting past the limit refuses
    /// the swap outright. That is a revert inside the lock, so it has to park.
    function test_aConversionIntoAPausedPoolManagerParksInsteadOfBrickingTheHarvest() public {
        manager.pause();
        meme.mint(address(sink), 100 ether);

        vm.expectEmit(true, false, false, true, address(sink));
        emit BuybackBurnSink.Parked(Currency.wrap(address(meme)), 100 ether, 3);
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);

        assertEq(meme.balanceOf(address(sink)), 100 ether, "the tranche should have parked here");
    }

    /// A caught failure must not spend the currency's window, and must not leave the transient
    /// lock flag set - the same two properties the buyback path has.
    function test_aFailedConversionSpendsNoWindowAndLeavesNoOpenLock() public {
        manager.pause();
        meme.mint(address(sink), 100 ether);
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);
        assertEq(sink.lastConvertAt(Currency.wrap(address(meme))), 0, "a failed conversion moved the clock");

        vm.prank(address(vault));
        vm.expectRevert(BuybackBurnSink.LockNotOpen.selector);
        sink.lockAcquired(abi.encode(uint256(1)));

        manager.unpause();
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);
        assertGt(sink.lastConvertAt(Currency.wrap(address(meme))), 0, "the retry was rate-limited by a failure");
        assertEq(meme.balanceOf(address(sink)), 0, "the parked tranche was not picked up");
    }

    /// D20 again: a conversion is a price-sensitive trade a permissionless caller times, so it
    /// is rate-limited. Per currency, or one launch token would gate every other one.
    function test_aConversionsWindowIsItsOwnCurrencysAlone() public {
        meme.mint(address(sink), 10 ether);
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);
        assertEq(meme.balanceOf(address(sink)), 0, "the first conversion did not run");

        // Same currency, same window: parks.
        meme.mint(address(sink), 10 ether);
        vm.expectEmit(true, false, false, true, address(sink));
        emit BuybackBurnSink.Parked(Currency.wrap(address(meme)), 10 ether, 1);
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);
        assertEq(meme.balanceOf(address(sink)), 10 ether, "a second conversion in the window traded");

        // A different currency is untouched by it.
        meme2.mint(address(sink), 10 ether);
        sink.convert(Currency.wrap(address(meme2)), MEME2_LAUNCH);
        assertEq(meme2.balanceOf(address(sink)), 0, "one launch token's window blocked another's");

        vm.warp(block.timestamp + INTERVAL);
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);
        assertEq(meme.balanceOf(address(sink)), 0, "the window reopened and it still did not convert");
    }

    function test_belowItsOwnMinimumALaunchTokenAccumulates() public {
        vm.prank(TIMELOCK);
        sink.setMinConvertAmount(Currency.wrap(address(meme)), 5 ether);

        meme.mint(address(sink), 1 ether);
        vm.expectEmit(true, false, false, true, address(sink));
        emit BuybackBurnSink.Parked(Currency.wrap(address(meme)), 1 ether, 0);
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);
        assertEq(meme.balanceOf(address(sink)), 1 ether, "dust should accumulate");

        meme.mint(address(sink), 4 ether);
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);
        assertEq(meme.balanceOf(address(sink)), 0, "reaching the minimum did not release it");
    }

    function test_canConvertTracksTheGuardsAndTheHint() public {
        Currency memeCurrency = Currency.wrap(address(meme));

        assertFalse(sink.canConvert(memeCurrency, MEME_LAUNCH), "an empty sink should not claim it can convert");
        meme.mint(address(sink), 10 ether);
        assertTrue(sink.canConvert(memeCurrency, MEME_LAUNCH), "funded and unrestricted, it should convert");

        vm.prank(TIMELOCK);
        sink.setHold(memeCurrency, true);
        assertFalse(sink.canConvert(memeCurrency, MEME_LAUNCH), "a held currency should report false");
        vm.prank(TIMELOCK);
        sink.setHold(memeCurrency, false);

        sink.convert(memeCurrency, MEME_LAUNCH);
        meme.mint(address(sink), 10 ether);
        assertFalse(sink.canConvert(memeCurrency, MEME_LAUNCH), "inside the interval it should report false");

        // A hint that would REVERT reads false rather than throwing, so a keeper can tell a bad
        // launch id from an empty balance without spending a transaction to find out.
        assertFalse(sink.canConvert(memeCurrency, MEME2_LAUNCH), "a mismatched hint should report false");
        assertFalse(sink.canConvert(memeCurrency, 999), "an unregistered launch should report false");

        assertFalse(sink.canConvert(Currency.wrap(address(quote)), MEME_LAUNCH), "the quote leg is not convertible");
        assertFalse(
            sink.canConvert(Currency.wrap(address(burnToken)), MEME_LAUNCH), "the burn token is not convertible"
        );
        assertFalse(sink.canConvert(Currency.wrap(address(stray)), MEME_LAUNCH), "a currency with no pool is not");
    }

    /// `convert` is off the harvest path, so unlike `burn` it is allowed to say what is wrong.
    function test_convertRefusesEitherLegOfTheBuyback() public {
        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(quote)))
        );
        sink.convert(Currency.wrap(address(quote)), MEME_LAUNCH);

        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(burnToken)))
        );
        sink.convert(Currency.wrap(address(burnToken)), MEME_LAUNCH);
    }

    /// 🔴 The load-bearing check on the one setter that can aim a conversion. A locker built
    /// against a DIFFERENT position manager would resolve a launch id through a manager this
    /// sink never agreed to read - so it is refused where the error names the cause, rather than
    /// installed and then silently answering with somebody else's pools.
    ///
    /// It doubles as an ABI proof: a contract with no `POSITION_MANAGER()` cannot be installed at
    /// all, which is the `_requireLockerSpeaksOurAbi` lesson from A3 in the place it applies here.
    function test_setLockersRefusesALockerOnAnotherPositionManager() public {
        MockPositionManager otherPosm = new MockPositionManager();
        MockPositionLocker foreign = new MockPositionLocker(ICLPositionManager(address(otherPosm)), TREASURY);

        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.LockerHasAnotherPositionManager.selector, address(foreign))
        );
        sink.setLockers(_one(address(foreign)));
    }

    /// A contract that is not a locker at all reverts inside the same check.
    function test_setLockersRefusesSomethingThatIsNotALocker() public {
        vm.prank(TIMELOCK);
        vm.expectRevert();
        sink.setLockers(_one(address(quote)));
    }

    function test_setLockersRefusesZeroDuplicatesAndOverLongLists() public {
        vm.startPrank(TIMELOCK);

        vm.expectRevert(BuybackBurnSink.ZeroAddress.selector);
        sink.setLockers(_one(address(0)));

        address[] memory twice = new address[](2);
        twice[0] = address(locker);
        twice[1] = address(locker);
        vm.expectRevert(abi.encodeWithSelector(BuybackBurnSink.DuplicateLocker.selector, address(locker)));
        sink.setLockers(twice);

        uint256 cap = sink.MAX_LOCKERS();
        address[] memory tooMany = new address[](cap + 1);
        for (uint256 i; i < tooMany.length; ++i) {
            tooMany[i] = address(new MockPositionLocker(ICLPositionManager(address(posm)), TREASURY));
        }
        vm.expectRevert(abi.encodeWithSelector(BuybackBurnSink.TooManyLockers.selector, cap + 1, cap));
        sink.setLockers(tooMany);

        vm.stopPrank();
    }

    /// The whole list every time, so removing one is stating the set without it - and the
    /// membership flag has to come back off, or a removed locker would still read as installed.
    function test_setLockersReplacesTheWholeSet() public {
        MockPositionLocker second = new MockPositionLocker(ICLPositionManager(address(posm)), TREASURY);

        address[] memory both = new address[](2);
        both[0] = address(locker);
        both[1] = address(second);
        vm.prank(TIMELOCK);
        sink.setLockers(both);
        assertTrue(sink.isLocker(address(locker)), "first locker is not installed");
        assertTrue(sink.isLocker(address(second)), "second locker is not installed");
        assertEq(sink.lockers().length, 2, "the set is the wrong size");

        vm.prank(TIMELOCK);
        sink.setLockers(_one(address(second)));
        assertFalse(sink.isLocker(address(locker)), "a dropped locker still reads as installed");
        assertTrue(sink.isLocker(address(second)), "the kept locker was dropped");
        assertEq(sink.lockers().length, 1, "the set was not replaced");
    }

    /// Neither leg of the buyback can be held, or `sweep`'s exclusion would be negotiable.
    function test_neitherBuybackLegCanBeHeld() public {
        vm.startPrank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(quote)))
        );
        sink.setHold(Currency.wrap(address(quote)), true);

        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(burnToken)))
        );
        sink.setHold(Currency.wrap(address(burnToken)), true);
        vm.stopPrank();
    }

    /// The contract's one invariant, restated over the leg A4 added and A5 narrowed: whatever the
    /// configuration and whatever the pool is doing, `burn` RETURNS. Fuzzed over the state rather
    /// than over the currency, because `ChoiceFeeController.harvest` can only ever hand this a
    /// currency it has just transferred - a token, always, never an arbitrary address.
    function testFuzz_burnNeverRevertsWhateverTheState(
        uint96 amount,
        bool held,
        bool paused,
        bool lockersSet,
        uint8 leg
    ) public {
        // A launch token with a pool, one on an older tier, and a currency with no pool anywhere.
        MockERC20 token = leg % 3 == 0 ? meme : (leg % 3 == 1 ? straggler : stray);
        Currency currency = Currency.wrap(address(token));

        BuybackBurnSink target = _freshSink();
        vm.startPrank(TIMELOCK);
        target.setBuybackPool(pool);
        target.setGuards(1 ether, 500, INTERVAL);
        if (lockersSet) target.setLockers(_one(address(locker)));
        if (held) target.setHold(currency, true);
        vm.stopPrank();

        token.mint(address(target), amount);
        if (paused) manager.pause();

        // No `expectRevert`, no `try`: the assertion is that this line returns at all.
        target.burn(currency, amount);

        if (paused) manager.unpause();
        // And nothing walked off with it - whatever happened, the funds are here or they are
        // the buyback pool that this contract went on to burn and split.
        assertEq(token.balanceOf(TREASURY), 0, "ops received a currency the burn was entitled to");
    }

    /// A5's counterpart. `convert` IS allowed to revert - on its arguments - so the invariant
    /// worth fuzzing is the narrower one: given a hint that resolves, it never reverts either,
    /// whatever the guards and the pool are doing. Anything else would make a keeper's batch
    /// fail on a launch that simply has nothing to do.
    function testFuzz_convertNeverRevertsOnAResolvableHint(uint96 amount, bool held, bool paused, bool straggle)
        public
    {
        MockERC20 token = straggle ? straggler : meme;
        uint256 launchId = straggle ? STRAGGLER_LAUNCH : MEME_LAUNCH;
        Currency currency = Currency.wrap(address(token));

        if (held) {
            vm.prank(TIMELOCK);
            sink.setHold(currency, true);
        }
        token.mint(address(sink), amount);
        if (paused) manager.pause();

        // No `expectRevert`, no `try`: the assertion is that this line returns at all.
        sink.convert(currency, launchId);

        if (paused) manager.unpause();
        assertEq(token.balanceOf(TREASURY), 0, "ops received a currency the burn was entitled to");
    }

    // ── the invariant: `burn` cannot revert, whatever the pool does ────────

    /// The whole point of the `try/catch`. `CLPoolManager.swap` is `whenNotPaused`, and the
    /// pause role exists to be used in an incident - so without this, reaching for the pause
    /// would also stop every protocol-fee harvest on the deployment.
    function test_aPausedPoolManagerParksInsteadOfBrickingTheHarvest() public {
        manager.pause();
        quote.mint(address(sink), 100 ether);

        vm.expectEmit(true, false, false, true, address(sink));
        emit BuybackBurnSink.Parked(Currency.wrap(address(quote)), 100 ether, 3);
        sink.burn(Currency.wrap(address(quote)), 100 ether);

        assertEq(quote.balanceOf(address(sink)), 100 ether, "the tranche should have parked here");
    }

    /// A caught failure must not spend the rate-limit window, or one paused block would push
    /// the next real buyback out by a full interval.
    function test_aFailedBuybackDoesNotConsumeTheRateLimitWindow() public {
        manager.pause();
        quote.mint(address(sink), 100 ether);
        sink.burn(Currency.wrap(address(quote)), 100 ether);
        assertEq(sink.lastBuybackAt(), 0, "a failed buyback moved the clock");

        manager.unpause();
        sink.buyback();
        assertGt(sink.lastBuybackAt(), 0, "the retry was rate-limited by a failure");
        assertEq(quote.balanceOf(address(sink)), 0, "the parked tranche was not picked up");
    }

    /// `_setLockOpen(true)` is written in `_tryBuyback`'s own frame, so the caught revert does
    /// NOT roll it back. If the flag were cleared only on the success path, the vault could
    /// call `lockAcquired` for the rest of the transaction after any failed buyback.
    function test_aFailedBuybackLeavesNoOpenLockBehind() public {
        manager.pause();
        quote.mint(address(sink), 100 ether);
        sink.burn(Currency.wrap(address(quote)), 100 ether);

        vm.prank(address(vault));
        vm.expectRevert(BuybackBurnSink.LockNotOpen.selector);
        sink.lockAcquired(abi.encode(uint256(1)));
    }

    // ── the same invariant, on the SETTLE rather than the pool ─────────────
    //
    // Every test above mocks a POOL failure, which is what the swap's `try/catch` covers. The
    // settle was outside that wrapper: `BURN_TOKEN.burn` and the transfer to `treasury` both
    // reach the bank precompile on a real `MintBurnBankERC20`, and `treasury` is owner-settable
    // to any address. Neither is unfailable, and either one reverting bricked the harvest.

    /// The direct path: `harvest` sent the burn token itself, so there is no swap to hide
    /// behind. A failing `burn` must park the tranche whole.
    function test_aFailingBurnParksTheTokensInsteadOfBrickingTheHarvest() public {
        burnToken.mint(address(sink), 10 ether);
        vm.mockCallRevert(address(burnToken), abi.encodeWithSelector(MockBurnableERC20.burn.selector), "burn is down");

        vm.expectEmit(true, false, false, true, address(sink));
        emit BuybackBurnSink.Parked(Currency.wrap(address(burnToken)), 10 ether, 4);
        sink.burn(Currency.wrap(address(burnToken)), 10 ether);

        assertEq(burnToken.balanceOf(address(sink)), 10 ether, "the tranche should have parked here intact");
        assertEq(burnToken.balanceOf(TREASURY), 0, "the treasury leg must not land on its own");
    }

    /// ⛔ THE reason the settle is one atomic self-call and not a `try` around each leg.
    ///
    /// With separate wrappers the burn lands, the transfer fails, and only the ops share is left
    /// sitting here - so the retry, which acts on the BALANCE like everything else in this
    /// contract, applies `burnBps` a second time and destroys 80% of the treasury's money. The
    /// split has to survive the failure whole, which means neither leg may land without the
    /// other.
    function test_aFailingTreasuryTransferLeavesTheWholeSplitForTheRetry() public {
        uint256 supplyBefore = burnToken.totalSupply();
        burnToken.mint(address(sink), 10 ether);
        vm.mockCallRevert(
            address(burnToken), abi.encodeWithSelector(IERC20.transfer.selector, TREASURY), "treasury is blocked"
        );

        sink.burn(Currency.wrap(address(burnToken)), 10 ether);

        assertEq(burnToken.totalSupply(), supplyBefore + 10 ether, "the burn leg landed without the treasury leg");
        assertEq(burnToken.balanceOf(address(sink)), 10 ether, "the tranche should have parked here intact");

        vm.clearMockedCalls();
        sink.burn(Currency.wrap(address(burnToken)), 10 ether);

        uint256 burnt = supplyBefore + 10 ether - burnToken.totalSupply();
        assertEq(burnt, 10 ether * uint256(FLOOR) / 10_000, "the retry did not burn burnBps of the WHOLE tranche");
        assertEq(burnToken.balanceOf(TREASURY), 10 ether - burnt, "the treasury did not get the remainder");
        assertEq(burnToken.balanceOf(address(sink)), 0, "the retry left something behind");
    }

    /// The buyback path is the worse of the two call sites: by the time the settle runs the swap
    /// has landed and `lastBuybackAt` is written, so a propagated revert would throw away a good
    /// buyback along with the harvest.
    function test_aFailingSettleDoesNotUnwindTheBuybackThatPrecededIt() public {
        quote.mint(address(sink), 100 ether);
        vm.mockCallRevert(address(burnToken), abi.encodeWithSelector(MockBurnableERC20.burn.selector), "burn is down");

        sink.burn(Currency.wrap(address(quote)), 100 ether);

        assertGt(sink.lastBuybackAt(), 0, "the swap was unwound along with the settle");
        assertEq(quote.balanceOf(address(sink)), 0, "the quote was not spent, so the swap did not stand");
        assertGt(burnToken.balanceOf(address(sink)), 0, "the bought burn token should be parked here");
        assertEq(burnToken.balanceOf(TREASURY), 0, "nothing should have reached the treasury");

        // Nothing is stranded: the balance is what the next call acts on.
        vm.clearMockedCalls();
        uint256 parked = burnToken.balanceOf(address(sink));
        sink.burn(Currency.wrap(address(burnToken)), 0);
        assertEq(burnToken.balanceOf(address(sink)), 0, "a later call did not pick the parked tranche up");
        assertEq(burnToken.balanceOf(TREASURY), parked - parked * FLOOR / 10_000, "the retry shortchanged the treasury");
    }

    /// It moves the burn token, so it exists only to be `try`ed from inside this contract. An
    /// open one would be a permissionless way to force the split at a chosen moment.
    function test_settleBurnTokenSelfIsCallableOnlyByTheContractItself() public {
        burnToken.mint(address(sink), 10 ether);

        vm.prank(STRANGER);
        vm.expectRevert(BuybackBurnSink.NotSelf.selector);
        sink.settleBurnTokenSelf();

        // Not an ownership gate either - the timelock has no more business calling it than
        // anyone else.
        vm.prank(TIMELOCK);
        vm.expectRevert(BuybackBurnSink.NotSelf.selector);
        sink.settleBurnTokenSelf();

        assertEq(burnToken.balanceOf(address(sink)), 10 ether, "a refused call moved something anyway");
    }

    // ── the second leg: a launch paired against another quote asset (D28/A2) ──

    /// 🔴 **The gap this closes, stated as a before and after.** Testnet launch 19 is
    /// SAI-paired: it graduated fine, its fees collect and claim fine, and the sink then refused
    /// them, having no second leg from SAI to wINJ. Both halves of its LP fee sat.
    function test_aSaiPairedGraduateIsRefusedUntilARouteExistsAndThenBurns() public {
        Currency pre2eCurrency = Currency.wrap(address(pre2e));
        pre2e.mint(address(sink), 100 ether);

        // BEFORE. A named revert, not a silent park - the caller is told what is missing.
        assertEq(sink.conversionRoute(pre2eCurrency, SAI_LAUNCH).legs, 0, "there should be no route yet");
        vm.expectRevert(abi.encodeWithSelector(BuybackBurnSink.LaunchDoesNotTrade.selector, SAI_LAUNCH, pre2eCurrency));
        sink.convert(pre2eCurrency, SAI_LAUNCH);

        // AFTER. One owner call, naming a venue rather than a destination.
        vm.prank(TIMELOCK);
        sink.setQuoteRoute(Currency.wrap(address(sai)), saiQuotePool);

        BuybackBurnSink.Route memory route = sink.conversionRoute(pre2eCurrency, SAI_LAUNCH);
        assertEq(route.legs, 2, "a SAI-paired graduate needs two legs");
        assertEq(
            PoolId.unwrap(route.first.toId()),
            PoolId.unwrap(saiLaunchPool.toId()),
            "the first leg must be the launch's OWN pool, still derived from its locked position"
        );
        assertEq(
            PoolId.unwrap(route.second.toId()),
            PoolId.unwrap(saiQuotePool.toId()),
            "the second leg must be the registered route"
        );

        uint256 supplyBefore = burnToken.totalSupply();
        sink.convert(pre2eCurrency, SAI_LAUNCH);

        assertEq(pre2e.balanceOf(address(sink)), 0, "the launch token did not convert");
        assertEq(sai.balanceOf(address(sink)), 0, "the intermediate should not linger in the sink");
        assertLt(burnToken.totalSupply(), supplyBefore, "a SAI-paired graduate's revenue never reached the burn");
    }

    /// 🔑 **The other half of a SAI-paired launch's fee, and it needs no hint at all.** A
    /// full-range position earns in BOTH currencies, so the launchpad's share of launch 19 is
    /// part PRE2E and part SAI - and SAI is not a launch token, so no launch id resolves it. It
    /// used to park with reason 6 for ever. A registered route IS the lookup, so `burn` alone
    /// moves it.
    function test_thePairAssetHalfOfTheFeeConvertsWithNoLaunchId() public {
        Currency saiCurrency = Currency.wrap(address(sai));
        sai.mint(address(sink), 500 ether);

        // BEFORE: it parks, and says exactly why.
        vm.expectEmit(true, false, false, true, address(sink));
        emit BuybackBurnSink.Parked(saiCurrency, 500 ether, 6);
        sink.burn(saiCurrency, 0);
        assertEq(sai.balanceOf(address(sink)), 500 ether, "a parked tranche must stay put");

        vm.prank(TIMELOCK);
        sink.setQuoteRoute(saiCurrency, saiQuotePool);

        uint256 supplyBefore = burnToken.totalSupply();
        sink.burn(saiCurrency, 0);

        assertEq(sai.balanceOf(address(sink)), 0, "the pair asset did not convert");
        assertLt(burnToken.totalSupply(), supplyBefore, "the pair asset's revenue never reached the burn");
    }

    /// ⚠️ **The registered route chooses a VENUE, never a destination.** Both checks in
    /// `setQuoteRoute` exist so that the owner's one lever cannot point revenue anywhere but
    /// `QUOTE`, which is immutable.
    function test_aRouteCannotRedirectRevenueAnywhereButQuote() public {
        Currency saiCurrency = Currency.wrap(address(sai));

        // A pool that does not touch QUOTE at all.
        PoolKey memory elsewhere = _key(sai, stray, FEE);
        _seed(elsewhere, 10_000 ether);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(BuybackBurnSink.RouteMissingLeg.selector, saiCurrency));
        sink.setQuoteRoute(saiCurrency, elsewhere);

        // A pool that trades the right pair on a tier nobody has opened. It would install
        // cleanly and then park every tranche, so it is refused where the error names the cause.
        PoolKey memory unopened = _key(sai, quote, 3000);
        vm.prank(TIMELOCK);
        vm.expectRevert(BuybackBurnSink.PoolNotInitialised.selector);
        sink.setQuoteRoute(saiCurrency, unopened);

        // And neither leg of the buyback is a routable asset: they have their own paths.
        vm.startPrank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(quote)))
        );
        sink.setQuoteRoute(Currency.wrap(address(quote)), saiQuotePool);
        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(burnToken)))
        );
        sink.setQuoteRoute(Currency.wrap(address(burnToken)), saiQuotePool);
        vm.stopPrank();
    }

    /// Only the owner can name a venue, and retiring one is an explicit call that emits.
    function test_onlyTheOwnerRoutes_andClearingRestoresTheRefusal() public {
        Currency saiCurrency = Currency.wrap(address(sai));

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        sink.setQuoteRoute(saiCurrency, saiQuotePool);

        vm.prank(TIMELOCK);
        sink.setQuoteRoute(saiCurrency, saiQuotePool);
        (,, bool found) = sink.quoteRoute(saiCurrency);
        assertTrue(found, "the route did not install");
        assertEq(sink.conversionRoute(Currency.wrap(address(pre2e)), SAI_LAUNCH).legs, 2, "two legs expected");

        PoolKey memory cleared;
        vm.prank(TIMELOCK);
        sink.setQuoteRoute(saiCurrency, cleared);
        (,, found) = sink.quoteRoute(saiCurrency);
        assertFalse(found, "a zero poolManager must clear the route");
        assertEq(
            sink.conversionRoute(Currency.wrap(address(pre2e)), SAI_LAUNCH).legs,
            0,
            "clearing a route must restore the refusal rather than leaving a stale path"
        );
    }

    /// 🔑 **`maxImpactBps` keeps ONE meaning however long the route is.** Giving each leg the
    /// full setting would silently let a two-leg conversion move prices twice as far as a
    /// one-leg one at the same number, so the allowance is SPLIT: two legs get half each, and
    /// the two moves sum to what one leg alone is allowed.
    ///
    /// Measured on the pools themselves, either side of a conversion far too large to fill.
    function test_theImpactBoundIsSplitAcrossTheLegsRatherThanAppliedTwice() public {
        vm.startPrank(TIMELOCK);
        sink.setGuards(1 ether, 500, INTERVAL);
        sink.setQuoteRoute(Currency.wrap(address(sai)), saiQuotePool);
        vm.stopPrank();

        // A one-leg conversion may walk its pool by the FULL 500 bps of sqrt price (250 either
        // side of the halving `_priceLimit` does).
        uint160 memeBefore = _sqrtPrice(memePool);
        meme.mint(address(sink), 10_000_000 ether);
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);
        uint256 oneLegMoveBps = _moveBps(memeBefore, _sqrtPrice(memePool));

        // A two-leg conversion gets 250 bps per leg instead.
        uint160 launchBefore = _sqrtPrice(saiLaunchPool);
        uint160 routeBefore = _sqrtPrice(saiQuotePool);
        pre2e.mint(address(sink), 10_000_000 ether);
        sink.convert(Currency.wrap(address(pre2e)), SAI_LAUNCH);
        uint256 legOneMoveBps = _moveBps(launchBefore, _sqrtPrice(saiLaunchPool));
        uint256 legTwoMoveBps = _moveBps(routeBefore, _sqrtPrice(saiQuotePool));

        // `memePool` and `saiLaunchPool` are the same shape - same tier, same spacing, both
        // seeded with 100,000 - and both are fed the same oversized tranche, so the two numbers
        // are directly comparable. That comparison IS the claim: the same setting gives a leg of
        // a two-leg route half of what it gives a one-leg conversion.
        assertApproxEqAbs(oneLegMoveBps, 250, 1, "a one-leg conversion should walk to its full allowance");
        assertApproxEqAbs(legOneMoveBps, 125, 1, "leg one of two should get half the allowance");

        // Leg two's share is a CEILING, not a target: leg one stopped at its own bound, so what
        // reached the route pool was far too small to walk it 125 bps. What must hold is that it
        // could not have gone further even if it were.
        assertLe(legTwoMoveBps, 126, "leg two exceeded its share of the allowance");
        assertLe(
            legOneMoveBps + legTwoMoveBps,
            oneLegMoveBps + 1,
            "two legs must not be allowed to move prices further in total than one"
        );
    }

    /// ⚠️ **A launch's PAIR asset must never be sold into the launch's own pool.** `convert(SAI,
    /// 19)` matches launch 19's pool - SAI is one of its two currencies - but selling SAI there
    /// buys the launch token, which is backwards. The resolution order is what prevents it: the
    /// launch's pool is tried first and DECLINES, because the other side is neither `QUOTE` nor
    /// a routable asset, and the registered route then takes it.
    function test_thePairAssetIsNeverSoldIntoTheLaunchsOwnPool() public {
        vm.prank(TIMELOCK);
        sink.setQuoteRoute(Currency.wrap(address(sai)), saiQuotePool);

        BuybackBurnSink.Route memory route = sink.conversionRoute(Currency.wrap(address(sai)), SAI_LAUNCH);
        assertEq(route.legs, 1, "the pair asset takes its route, not two hops through the launch");
        assertEq(
            PoolId.unwrap(route.first.toId()),
            PoolId.unwrap(saiQuotePool.toId()),
            "the pair asset was routed through the launch's own pool"
        );

        uint160 launchPriceBefore = _sqrtPrice(saiLaunchPool);
        sai.mint(address(sink), 100 ether);
        sink.convert(Currency.wrap(address(sai)), SAI_LAUNCH);
        assertEq(_sqrtPrice(saiLaunchPool), launchPriceBefore, "the launch's own pool was traded");
    }

    /// The anchored path wins. A launch token that somehow also had a route registered still
    /// converts through the pool its settler opened, because that is the one nobody chose.
    function test_theLaunchsOwnPoolIsPreferredOverARegisteredRoute() public {
        PoolKey memory rival = _key(meme, quote, OLD_FEE);
        _seed(rival, 50_000 ether);

        vm.prank(TIMELOCK);
        sink.setQuoteRoute(Currency.wrap(address(meme)), rival);

        BuybackBurnSink.Route memory route = sink.conversionRoute(Currency.wrap(address(meme)), MEME_LAUNCH);
        assertEq(route.legs, 1, "one leg either way");
        assertEq(
            PoolId.unwrap(route.first.toId()),
            PoolId.unwrap(memePool.toId()),
            "a registered route displaced the launch's own anchored pool"
        );
    }

    // ── guards that fail where they are set, not where they bite ───────────

    /// `_priceLimit` halves the setting, so 0 and 1 both produce a bound equal to the pool's
    /// own price - which no swap can cross. This was the value a sink carried before
    /// `setGuards` had ever been called.
    ///
    /// 🔴 The floor is **4** since conversions became two-legged, not 2. `maxImpactBps` bounds
    /// the WHOLE conversion, so a two-leg route halves it before `_priceLimit` halves it again -
    /// and at 2 or 3 the second leg's limit would truncate to its pool's own price. The floor
    /// has to be the smallest number that is still a bound on the LONGEST route this contract
    /// can build, or the guard would be real for one-leg conversions and vacuous for two.
    function test_anImpactGuardBelowItsFloorIsRefused() public {
        uint16 floor = sink.MIN_IMPACT_BPS();
        assertEq(floor, 4, "the floor must cover the two-leg split");

        vm.startPrank(TIMELOCK);
        for (uint16 bps = 0; bps < floor; bps++) {
            vm.expectRevert(abi.encodeWithSelector(BuybackBurnSink.ImpactBpsTooLow.selector, bps, floor));
            sink.setGuards(1 ether, bps, INTERVAL);
        }
        sink.setGuards(1 ether, floor, INTERVAL); // the floor itself is fine
        vm.stopPrank();
        assertEq(sink.maxImpactBps(), floor);
    }

    /// D20 is answered by the rate limit, so the rate limit is not optional.
    function test_aRateLimitOfZeroIsRefused() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(BuybackBurnSink.RateLimitRequired.selector);
        sink.setGuards(1 ether, 500, 0);
    }

    /// Both legs being right does not make the pool exist. A key on an unopened tier used to
    /// install cleanly and then park every tranche silently.
    function test_setBuybackPoolRejectsAPoolThatWasNeverInitialised() public {
        PoolKey memory ghost = _key(quote, burnToken, 3000); // same legs, a tier nobody opened
        vm.prank(TIMELOCK);
        vm.expectRevert(BuybackBurnSink.PoolNotInitialised.selector);
        sink.setBuybackPool(ghost);
    }

    // ── the floor: the whole differentiator ───────────────────────────────

    function test_burnBpsCannotBeLoweredPastTheFloor() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(BuybackBurnSink.BurnBpsBelowFloor.selector, uint16(7999), FLOOR));
        sink.setBurnBps(7999);

        assertEq(sink.burnBps(), FLOOR, "burnBps moved despite the revert");
    }

    function test_burnBpsIsBoundedByItsFloorNotByItsCurrentValue() public {
        vm.startPrank(TIMELOCK);
        sink.setBurnBps(9500);
        assertEq(sink.burnBps(), 9500, "the share did not move up");

        // Still bounded by the FLOOR, not by the new value: the floor is the promise.
        sink.setBurnBps(FLOOR);
        assertEq(sink.burnBps(), FLOOR, "returning to the floor should be allowed");

        vm.expectRevert(abi.encodeWithSelector(BuybackBurnSink.BurnBpsBelowFloor.selector, uint16(0), FLOOR));
        sink.setBurnBps(0);
        vm.stopPrank();
    }

    function test_constructorRejectsABurnShareUnderItsOwnFloor() public {
        vm.expectRevert(abi.encodeWithSelector(BuybackBurnSink.BurnBpsBelowFloor.selector, uint16(5000), FLOOR));
        new BuybackBurnSink(
            IBurnableERC20(address(burnToken)),
            Currency.wrap(address(quote)),
            IVault(address(vault)),
            ICLPositionManager(address(posm)),
            TREASURY,
            TIMELOCK,
            FLOOR,
            5000
        );
    }

    // ── what the owner cannot do ──────────────────────────────────────────

    /// Revenue rests in this contract between harvests, so an unrestricted sweep would be a way
    /// to take burn revenue before it is burnt.
    function test_sweepCannotTouchEitherLegOfTheBuyback() public {
        quote.mint(address(sink), 10 ether);
        deal(address(burnToken), address(sink), 10 ether);

        vm.startPrank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.CannotSweepBuybackLeg.selector, Currency.wrap(address(quote)))
        );
        sink.sweep(Currency.wrap(address(quote)), TIMELOCK);

        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.CannotSweepBuybackLeg.selector, Currency.wrap(address(burnToken)))
        );
        sink.sweep(Currency.wrap(address(burnToken)), TIMELOCK);
        vm.stopPrank();

        assertEq(quote.balanceOf(address(sink)), 10 ether, "quote left the sink");
        assertEq(burnToken.balanceOf(address(sink)), 10 ether, "burn token left the sink");
    }

    /// 🔴 A launch token became burn revenue the moment it became convertible, so excluding
    /// only wINJ and the burn token stopped being enough. Sweeping now needs the D32 designation, which
    /// makes taking one out two calls that both emit rather than one that looks like tidying.
    function test_sweepNeedsTheHoldDesignationFirst() public {
        meme.mint(address(sink), 7 ether);

        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.SweepRequiresHold.selector, Currency.wrap(address(meme)))
        );
        sink.sweep(Currency.wrap(address(meme)), TREASURY);
        assertEq(meme.balanceOf(address(sink)), 7 ether, "convertible revenue left the sink");

        vm.startPrank(TIMELOCK);
        sink.setHold(Currency.wrap(address(meme)), true);
        sink.sweep(Currency.wrap(address(meme)), TREASURY);
        vm.stopPrank();

        assertEq(meme.balanceOf(TREASURY), 7 ether, "the designated token was not recovered");
    }

    /// The same route out for a donation with no pool behind it: designate, then sweep.
    function test_sweepRecoversAStrandedThirdCurrency() public {
        stray.mint(address(sink), 7 ether);

        vm.startPrank(TIMELOCK);
        sink.setHold(Currency.wrap(address(stray)), true);
        sink.sweep(Currency.wrap(address(stray)), TREASURY);
        vm.stopPrank();

        assertEq(stray.balanceOf(TREASURY), 7 ether, "the stranded token was not recovered");
    }

    function test_ownerOnlySettersRejectAStranger() public {
        vm.startPrank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        sink.setBurnBps(9000);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        sink.setGuards(1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        sink.setTreasury(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        sink.setLockers(_one(address(locker)));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        sink.setHold(Currency.wrap(address(meme)), true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        sink.setMinConvertAmount(Currency.wrap(address(meme)), 1);
        vm.stopPrank();
    }

    /// A key that does not actually trade the pair would park revenue silently forever.
    function test_setBuybackPoolRejectsAKeyMissingALeg() public {
        PoolKey memory wrong = _key(quote, stray, FEE);
        vm.prank(TIMELOCK);
        vm.expectRevert(BuybackBurnSink.PoolMissingLeg.selector);
        sink.setBuybackPool(wrong);
    }

    function test_setBuybackPoolDerivesTheSwapDirection() public view {
        bool quoteIsFirst = address(quote) < address(burnToken);
        assertEq(sink.quoteIsCurrency0(), quoteIsFirst, "swap direction was derived wrongly");
    }

    // ── the lock callback ─────────────────────────────────────────────────

    function test_lockAcquiredRejectsANonVaultCaller() public {
        vm.prank(STRANGER);
        vm.expectRevert(BuybackBurnSink.NotVault.selector);
        sink.lockAcquired(abi.encode(uint256(1)));
    }

    /// Gated on a lock THIS contract opened, not merely on the vault's identity.
    function test_lockAcquiredRejectsTheVaultOutsideAnOpenLock() public {
        vm.prank(address(vault));
        vm.expectRevert(BuybackBurnSink.LockNotOpen.selector);
        sink.lockAcquired(abi.encode(uint256(1)));
    }

    function test_transientSlotMatchesItsDerivation() public pure {
        uint256 derived = uint256(keccak256("choice.v2.buybackburnsink.lockOpen")) - 1;
        assertEq(derived, 0xbb393ca8346e746397cbb72e3dd898fcb21e70d8c1e3b5ee10773bc10d26776e, "slot literal drifted");
    }

    // ── helpers ───────────────────────────────────────────────────────────

    // ---------------------------------------------------------------------------------------
    // 1.5.0 — DERIVED quote hops. A launch paired against anything but QUOTE used to need a
    // governance transaction before its fee could ever burn; these prove it no longer does,
    // and that derivation cannot be used to point the sink anywhere it should not go.

    /// The item itself: a quote asset nobody registered, whose `{asset, QUOTE}` pool exists on a
    /// standard tier, converts. Before 1.5.0 this parked for ever with nothing failing.
    function test_aQuoteAssetWithAStandardTierPoolConvertsWithNothingRegistered() public {
        posm.setPoolManager(address(manager));
        BuybackBurnSink fresh = _freshSink();

        (,, bool found) = fresh.quoteRoute(Currency.wrap(address(sai)));
        assertTrue(found, "a standard-tier pool should be derivable with nothing registered");

        (,, bool pinned) = fresh.registeredQuoteRoute(Currency.wrap(address(sai)));
        assertFalse(pinned, "and it should be derived, not pinned");

        _configure(fresh);
        sai.mint(address(fresh), 500 ether);
        fresh.burn(Currency.wrap(address(sai)), 0);
        assertEq(sai.balanceOf(address(fresh)), 0, "the pair asset should have converted");
    }

    /// Governance still wins. A pinned route is checked BEFORE the tier search, so an operator
    /// can always move a conversion off a pool derivation would have picked.
    function test_aRegisteredRouteOverridesTheDerivedOne() public {
        posm.setPoolManager(address(manager));
        BuybackBurnSink fresh = _freshSink();

        PoolKey memory override_ = _key(sai, quote, OLD_FEE);
        _seed(override_, 5_000 ether);

        vm.prank(TIMELOCK);
        fresh.setQuoteRoute(Currency.wrap(address(sai)), override_);

        (PoolKey memory used,, bool found) = fresh.quoteRoute(Currency.wrap(address(sai)));
        assertTrue(found, "the pinned route should resolve");
        assertEq(used.fee, OLD_FEE, "the pinned route must win over the derived one");
    }

    /// Several tiers may hold the same pair. Taking the first would send a conversion through a
    /// tier somebody opened with dust while the real book sat one tier away.
    function test_derivationPrefersTheDeepestTier() public {
        posm.setPoolManager(address(manager));

        PoolKey memory thin = _key(sai, quote, OLD_FEE);
        _seed(thin, 1_000 ether);

        BuybackBurnSink fresh = _freshSink();
        (PoolKey memory used,, bool found) = fresh.quoteRoute(Currency.wrap(address(sai)));
        assertTrue(found, "both tiers exist, one must be chosen");
        assertEq(used.fee, FEE, "the deeper tier should win");
    }

    /// ⛔ The safety property. A derived key is built by this contract — currencies sorted,
    /// `hooks` ZERO, manager taken from the immutable position manager — so no pool anyone else
    /// created with a hook can ever be routed through, however deep it is.
    function test_derivationNeverRoutesThroughAHookedPool() public {
        posm.setPoolManager(address(manager));
        BuybackBurnSink fresh = _freshSink();

        (PoolKey memory used,, bool found) = fresh.quoteRoute(Currency.wrap(address(sai)));
        assertTrue(found, "the hookless pool is still derivable");
        assertEq(address(used.hooks), address(0), "a derived hop must never carry a hook");
        assertEq(address(used.poolManager), address(manager), "and never another manager");
    }

    /// An asset with no pool at all stays unroutable, and `burn` still parks rather than reverts.
    function test_anAssetWithNoPoolAnywhereStaysUnroutable() public {
        posm.setPoolManager(address(manager));
        BuybackBurnSink fresh = _freshSink();

        (,, bool found) = fresh.quoteRoute(Currency.wrap(address(stray)));
        assertFalse(found, "nothing should be derivable for a currency with no pool");

        _configure(fresh);
        stray.mint(address(fresh), 100 ether);
        fresh.burn(Currency.wrap(address(stray)), 0);
        assertEq(stray.balanceOf(address(fresh)), 100 ether, "it should park, not revert");
    }

    function _key(MockERC20 a, MockERC20 b, uint24 fee) internal view returns (PoolKey memory) {
        (address c0, address c1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(manager)),
            fee: fee,
            parameters: bytes32(0).setTickSpacing(SPACING)
        });
    }

    /// The wiring `setUp` gives the fixture sink, for a sink built later in a test.
    function _configure(BuybackBurnSink s) internal {
        vm.startPrank(TIMELOCK);
        s.setBuybackPool(pool);
        s.setLockers(_one(address(locker)));
        s.setGuards(1 ether, 500, INTERVAL);
        vm.stopPrank();
    }

    function _freshSink() internal returns (BuybackBurnSink) {
        return new BuybackBurnSink(
            IBurnableERC20(address(burnToken)),
            Currency.wrap(address(quote)),
            IVault(address(vault)),
            ICLPositionManager(address(posm)),
            TREASURY,
            TIMELOCK,
            FLOOR,
            FLOOR
        );
    }

    /// Register a launch the way graduation does: the locker knows the position, the position
    /// manager knows its pool. Two lookups is all the sink ever makes.
    function _lock(uint256 launchId, uint256 tokenId, PoolKey memory key) internal {
        posm.setPool(tokenId, key);
        locker.register(launchId, tokenId);
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    /// The `parameters` word a graduation pool carries: the hook's registration bitmap in the
    /// low bits, the tier's spacing above it - exactly `InfinitySettler.poolParameters()`.
    function _graduationParameters() internal view returns (bytes32) {
        return bytes32(uint256(guardHook.getHooksRegistrationBitmap())).setTickSpacing(SPACING);
    }

    /// The key `InfinitySettler` would graduate `token` onto, built the way the settler builds
    /// it: currencies sorted, the tier's fee and spacing, keyed to the guard hook.
    function _graduationKey(MockERC20 token, uint24 fee) internal view returns (PoolKey memory) {
        return _pairKey(token, quote, fee);
    }

    /// The same, for a launch paired against something that is NOT this sink's quote asset.
    function _pairKey(MockERC20 token, MockERC20 pair, uint24 fee) internal view returns (PoolKey memory) {
        (address c0, address c1) =
            address(token) < address(pair) ? (address(token), address(pair)) : (address(pair), address(token));
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(address(guardHook)),
            poolManager: IPoolManager(address(manager)),
            fee: fee,
            parameters: _graduationParameters()
        });
    }

    function _sqrtPrice(PoolKey memory key) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(key.toId());
    }

    /// How far a pool's sqrt price moved, in basis points, either direction.
    function _moveBps(uint160 before, uint160 present) internal pure returns (uint256) {
        uint256 diff = present > before ? present - before : before - present;
        return diff * 10_000 / uint256(before);
    }

    function _seed(PoolKey memory key, uint256 amount) internal {
        manager.initialize(key, SQRT_1_1);
        MockERC20(Currency.unwrap(key.currency0)).mint(address(this), amount);
        MockERC20(Currency.unwrap(key.currency1)).mint(address(this), amount);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(seeder), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(seeder), type(uint256).max);
        seeder.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -887200, tickUpper: 887200, liquidityDelta: int256(amount / 2), salt: bytes32(0)
            }),
            ""
        );
    }
}
