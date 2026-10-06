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
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

import {IBuybackBurnSink} from "../src/interfaces/IBuybackBurnSink.sol";
import {deployBuybackBurnSink} from "./utils/DeployBuybackBurnSink.sol";
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
    address internal constant OPERATOR = address(0x0FE8);

    uint24 internal constant FEE = 10_000; // the launchpad's 1% graduation tier
    int24 internal constant SPACING = 200;
    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;

    /// An attacker's price: ~1e-6 of 1:1, i.e. the sink's asset valued at a millionth of what a
    /// real book would pay. The band is the spacing-aligned pair straddling the tick that price
    /// sits at (~-138163), so the position is in range and the pool is a live candidate.
    uint160 internal constant JIT_SQRT_PRICE = SQRT_1_1 / 1000;
    int24 internal constant JIT_TICK_LOWER = -138400;
    int24 internal constant JIT_TICK_UPPER = -138000;

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
    /// The burn token's own launch. Since 1.8.0 the buyback pool is named by launch id, and every
    /// buyback is sized against that launch's locked position (`BURN_POSITION`).
    uint256 internal constant BURN_LAUNCH = 1;
    uint256 internal constant BURN_POSITION = 5;

    /// A tranche cap the routing tests never reach. 1.8.0 makes the cap mandatory (zero is
    /// "unset", and nothing trades). The tests about the cap set a real one.
    uint256 internal constant LOOSE_TRANCHE = 10_000_000 ether;
    /// A quote-route depth ceiling that never binds, for the same reason. The tests about depth
    /// name a real one.
    uint128 internal constant UNBOUND_DEPTH = type(uint128).max;

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

    IBuybackBurnSink internal sink;
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
        // to the guard hook. As deep as the buyback pool since 1.7.0: a guard-hooked pool's
        // sandwich bound is its LP fee times the launchpad's share (0.3% here), and these
        // fixtures exist to prove ROUTING, so a 100-token conversion has to fit inside one window.
        // The tests that are about the bound feed an oversized tranche on purpose.
        memePool = _graduationKey(meme, FEE);
        _seed(memePool, 1_000_000 ether);
        meme2Pool = _graduationKey(meme2, FEE);
        _seed(meme2Pool, 1_000_000 ether);

        // And one on the tier launches graduated on BEFORE A0. Same hook, same spacing, one fee
        // field different - which is all it took to make A4's derived key miss it.
        stragglerPool = _graduationKey(straggler, OLD_FEE);
        _seed(stragglerPool, 1_000_000 ether);

        // Launch 19's shape: the graduate trades against SAI, and SAI reaches wINJ through an
        // ordinary pool nobody's settler opened.
        saiLaunchPool = _pairKey(pre2e, sai, FEE);
        _seed(saiLaunchPool, 1_000_000 ether);
        saiQuotePool = _key(sai, quote, FEE);
        _seed(saiQuotePool, 500_000 ether);

        // The chain a launch id walks: locker says which position, position manager says which
        // pool. Registered here rather than derived, which is the whole of A5.
        _lock(MEME_LAUNCH, 1, memePool);
        _lock(MEME2_LAUNCH, 2, meme2Pool);
        _lock(STRAGGLER_LAUNCH, 3, stragglerPool);
        _lock(SAI_LAUNCH, 4, saiLaunchPool);
        // The burn token graduated too. Its pool is the buyback pool, read off its locked
        // position (1.8.0). `setPool` gives it a liquidity that never binds, so these tests size
        // against the pool as they always did. The anchoring tests replace it with a real one.
        _lock(BURN_LAUNCH, BURN_POSITION, pool);

        vm.startPrank(TIMELOCK);
        sink.setLockers(_one(address(locker)));
        sink.setBuybackLaunch(BURN_LAUNCH);
        // 1 wINJ minimum, 500 bps of sqrt-price headroom, one window per half hour. The rate
        // limit is not optional any more - `setGuards` refuses zero - so the fixture carries a
        // production-shaped value and tests that want a second buyback warp past it.
        sink.setGuards(1 ether, 500, INTERVAL);
        sink.setMaxBuybackAmount(LOOSE_TRANCHE);
        vm.stopPrank();
    }

    // ── the reason this contract exists ───────────────────────────────────

    /// The whole loop, end to end: 80% of revenue becomes the burn token and ALL of that is
    /// destroyed for real, and the other 20% reaches the treasury as quote (1.8.0). 1.7.0 bought
    /// with 100% and paid ops in the burn token.
    function test_eightyPercentOfRevenueIsBurntAndTwentyIsPaidInQuote() public {
        uint256 supplyBefore = burnToken.totalSupply();
        quote.mint(address(sink), 100 ether);

        sink.burn(Currency.wrap(address(quote)), 100 ether);

        uint256 burnt = supplyBefore - burnToken.totalSupply();
        assertGt(burnt, 0, "nothing was bought");
        assertEq(burnToken.balanceOf(TREASURY), 0, "ops was paid in the burn token");
        assertEq(burnToken.balanceOf(address(sink)), 0, "burn tokens were left sitting in the sink");
        assertEq(quote.balanceOf(TREASURY), 20 ether, "ops is not 20% of revenue, in quote");
        assertEq(sink.treasuryOwed(), 0, "the ops share was set aside but never paid");
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

        assertGt(burnt, 0, "the launch token parked instead of burning");
        assertEq(burnToken.balanceOf(TREASURY), 0, "ops was paid in the burn token");
        assertGt(quote.balanceOf(TREASURY), 0, "the conversion's ops share was never paid");
        assertEq(meme.balanceOf(address(sink)), 0, "the launch token was not fully converted");
        // `burnBps` of it bought, the rest paid out: rounding leaves at most a wei or two.
        assertLe(quote.balanceOf(address(sink)), 2, "the wINJ it converted to was not spent");
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
        emit IBuybackBurnSink.Parked(Currency.wrap(address(meme)), 100 ether, 6);
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
        IBuybackBurnSink fresh = _freshSink();
        meme.mint(address(fresh), 100 ether);

        vm.expectEmit(true, false, false, true, address(fresh));
        emit IBuybackBurnSink.Parked(Currency.wrap(address(meme)), 100 ether, 6);
        fresh.burn(Currency.wrap(address(meme)), 100 ether);

        assertEq(meme.balanceOf(address(fresh)), 100 ether, "funds should be held until a locker exists");
    }

    /// An unconfigured sink must also park rather than revert, or wiring it in the wrong order
    /// would brick harvests until someone noticed.
    function test_burnDoesNotRevertBeforeAPoolIsConfigured() public {
        IBuybackBurnSink fresh = _freshSink();
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
        assertGt(quote.balanceOf(TREASURY), 0, "a partial fill still has to pay its ops share");
        assertEq(burnToken.balanceOf(address(sink)), 0, "a partial fill still has to settle its burn");
    }

    function test_belowTheMinimumRevenueAccumulatesInsteadOfTrading() public {
        quote.mint(address(sink), 0.5 ether); // under the 1 ether floor

        sink.burn(Currency.wrap(address(quote)), 0.5 ether);

        assertEq(quote.balanceOf(address(sink)), 0.5 ether, "dust should accumulate");
        assertEq(sink.lastBuybackAt(), 0, "nothing should have been bought");
    }

    /// D20: without a rate limit a searcher picks the moment of every buyback. With one, a
    /// second call in the same window parks instead of trading.
    function test_rateLimitParksASecondBuybackInTheSameWindow() public {
        vm.prank(TIMELOCK);
        sink.setGuards(1 ether, 500, 1 hours);

        quote.mint(address(sink), 100 ether);
        sink.burn(Currency.wrap(address(quote)), 100 ether);
        uint256 afterFirst = burnToken.totalSupply();
        assertGt(sink.lastBuybackAt(), 0, "the first buyback should have run");

        quote.mint(address(sink), 100 ether);
        sink.burn(Currency.wrap(address(quote)), 100 ether);
        assertEq(burnToken.totalSupply(), afterFirst, "the second buyback should have been rate-limited");
        assertEq(quote.balanceOf(address(sink)), 100 ether, "the parked tranche should still be here");

        vm.warp(block.timestamp + 1 hours);
        sink.buyback();
        assertLt(burnToken.totalSupply(), afterFirst, "the window reopened and it still did not run");
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
        IBuybackBurnSink.Route memory route = sink.conversionRoute(Currency.wrap(address(meme)), MEME_LAUNCH);

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

        IBuybackBurnSink.Route memory route = sink.conversionRoute(Currency.wrap(address(straggler)), STRAGGLER_LAUNCH);
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
                IBuybackBurnSink.LaunchDoesNotTrade.selector, MEME2_LAUNCH, Currency.wrap(address(meme))
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
                IBuybackBurnSink.LaunchDoesNotTrade.selector, uint256(999), Currency.wrap(address(meme))
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
                IBuybackBurnSink.LaunchDoesNotTrade.selector, uint256(777), Currency.wrap(address(meme))
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
                IBuybackBurnSink.LaunchDoesNotTrade.selector, uint256(30), Currency.wrap(address(token))
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
        emit IBuybackBurnSink.Parked(Currency.wrap(address(meme)), 100 ether, 5);
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);

        assertEq(meme.balanceOf(address(sink)), 100 ether, "a held token should accumulate");
        assertEq(burnToken.totalSupply(), supplyBefore, "a held token must not reach the burn");

        // A held token reports the POLICY through `burn` too, rather than the missing hint.
        vm.expectEmit(true, false, false, true, address(sink));
        emit IBuybackBurnSink.Parked(Currency.wrap(address(meme)), 100 ether, 5);
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
        assertGt(quote.balanceOf(TREASURY), 0, "a partial conversion still has to reach the buyback");
    }

    /// And the harder case the bound can produce: a pool already sitting past the limit refuses
    /// the swap outright. That is a revert inside the lock, so it has to park.
    function test_aConversionIntoAPausedPoolManagerParksInsteadOfBrickingTheHarvest() public {
        manager.pause();
        meme.mint(address(sink), 100 ether);

        vm.expectEmit(true, false, false, true, address(sink));
        emit IBuybackBurnSink.Parked(Currency.wrap(address(meme)), 100 ether, 3);
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
        vm.expectRevert(IBuybackBurnSink.LockNotOpen.selector);
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
        emit IBuybackBurnSink.Parked(Currency.wrap(address(meme)), 10 ether, 1);
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
        emit IBuybackBurnSink.Parked(Currency.wrap(address(meme)), 1 ether, 0);
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
            abi.encodeWithSelector(IBuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(quote)))
        );
        sink.convert(Currency.wrap(address(quote)), MEME_LAUNCH);

        vm.expectRevert(
            abi.encodeWithSelector(IBuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(burnToken)))
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
            abi.encodeWithSelector(IBuybackBurnSink.LockerHasAnotherPositionManager.selector, address(foreign))
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

        vm.expectRevert(IBuybackBurnSink.ZeroAddress.selector);
        sink.setLockers(_one(address(0)));

        address[] memory twice = new address[](2);
        twice[0] = address(locker);
        twice[1] = address(locker);
        vm.expectRevert(abi.encodeWithSelector(IBuybackBurnSink.DuplicateLocker.selector, address(locker)));
        sink.setLockers(twice);

        uint256 cap = sink.MAX_LOCKERS();
        address[] memory tooMany = new address[](cap + 1);
        for (uint256 i; i < tooMany.length; ++i) {
            tooMany[i] = address(new MockPositionLocker(ICLPositionManager(address(posm)), TREASURY));
        }
        vm.expectRevert(abi.encodeWithSelector(IBuybackBurnSink.TooManyLockers.selector, cap + 1, cap));
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
            abi.encodeWithSelector(IBuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(quote)))
        );
        sink.setHold(Currency.wrap(address(quote)), true);

        vm.expectRevert(
            abi.encodeWithSelector(IBuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(burnToken)))
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

        IBuybackBurnSink target = _freshSink();
        vm.startPrank(TIMELOCK);
        target.setGuards(1 ether, 500, INTERVAL);
        if (lockersSet) {
            target.setLockers(_one(address(locker)));
            target.setBuybackLaunch(BURN_LAUNCH);
            target.setMaxBuybackAmount(LOOSE_TRANCHE);
        }
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
        // The tranche is `burnBps` of the balance: the other 20% is never the buyback's to offer.
        emit IBuybackBurnSink.Parked(Currency.wrap(address(quote)), 80 ether, 3);
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
        vm.expectRevert(IBuybackBurnSink.LockNotOpen.selector);
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
        emit IBuybackBurnSink.Parked(Currency.wrap(address(burnToken)), 10 ether, 4);
        sink.burn(Currency.wrap(address(burnToken)), 10 ether);

        assertEq(burnToken.balanceOf(address(sink)), 10 ether, "the tranche should have parked here intact");
        assertEq(burnToken.balanceOf(TREASURY), 0, "the treasury leg must not land on its own");
    }

    /// 1.8.0: a burn token that reaches the sink directly is destroyed WHOLE. The ops share is
    /// taken in quote before buying, so there is no split left to apply to it.
    function test_aBurnTokenTrancheIsDestroyedWhole() public {
        uint256 supplyBefore = burnToken.totalSupply();
        burnToken.mint(address(sink), 10 ether);

        sink.burn(Currency.wrap(address(burnToken)), 10 ether);

        assertEq(burnToken.totalSupply(), supplyBefore, "not all of it was burnt");
        assertEq(burnToken.balanceOf(TREASURY), 0, "ops was paid in the burn token");
    }

    /// The ops payout and the burn fail independently since 1.8.0, and each is simply retried.
    /// 1.7.0 needed one atomic self-call because both legs split ONE balance, so a half-done
    /// split would have been re-split on the retry. The ops share now lives in its own ledger.
    /// A blocked payout leaves it there, the buyback and the burn still land, and later buybacks
    /// never spend it.
    function test_aBlockedOpsPayoutStaysOwedAndIsNeverSpent() public {
        uint256 supplyBefore = burnToken.totalSupply();
        quote.mint(address(sink), 100 ether);
        vm.mockCallRevert(address(quote), abi.encodeWithSelector(IERC20.transfer.selector, TREASURY), "blocked");

        vm.expectEmit(true, false, false, true, address(sink));
        emit IBuybackBurnSink.Parked(Currency.wrap(address(quote)), 20 ether, 4);
        sink.burn(Currency.wrap(address(quote)), 100 ether);

        assertLt(burnToken.totalSupply(), supplyBefore, "a blocked payout stopped the burn");
        assertEq(sink.treasuryOwed(), 20 ether, "the ops share was not kept for the retry");
        assertEq(quote.balanceOf(address(sink)), 20 ether, "the owed quote left the sink");
        assertEq(sink.pendingQuote(), 0, "owed quote is reported as the buyback's to spend");

        // More revenue: the next buyback offers `burnBps` of what is NOT owed, never the owed.
        quote.mint(address(sink), 100 ether);
        vm.warp(block.timestamp + INTERVAL);
        sink.buyback();
        assertEq(sink.treasuryOwed(), 40 ether, "the second buyback's share was not set aside");
        assertEq(quote.balanceOf(address(sink)), 40 ether, "a buyback spent quote the treasury was owed");

        vm.clearMockedCalls();
        sink.payTreasury();
        assertEq(quote.balanceOf(TREASURY), 40 ether, "the retry did not pay the whole debt");
        assertEq(sink.treasuryOwed(), 0, "the debt survived its payment");
        assertEq(quote.balanceOf(address(sink)), 0, "something was left behind");
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
        assertEq(quote.balanceOf(TREASURY), 20 ether, "a failed burn held up the ops payout");
        assertGt(burnToken.balanceOf(address(sink)), 0, "the bought burn token should be parked here");

        // Nothing is stranded: the balance is what the next call acts on, and all of it burns.
        vm.clearMockedCalls();
        sink.burn(Currency.wrap(address(burnToken)), 0);
        assertEq(burnToken.balanceOf(address(sink)), 0, "a later call did not pick the parked tranche up");
        assertEq(burnToken.balanceOf(TREASURY), 0, "the retry paid ops in the burn token");
    }

    /// Both settle legs exist only to be `try`ed from inside this contract. Open ones would let a
    /// stranger choose the moment of the burn or the payout.
    function test_theSettleLegsAreCallableOnlyByTheContractItself() public {
        burnToken.mint(address(sink), 10 ether);

        vm.prank(STRANGER);
        vm.expectRevert(IBuybackBurnSink.NotSelf.selector);
        sink.settleBurnTokenSelf();
        vm.prank(STRANGER);
        vm.expectRevert(IBuybackBurnSink.NotSelf.selector);
        sink.payTreasurySelf();

        // Not an ownership gate either - the timelock has no more business calling it than
        // anyone else.
        vm.prank(TIMELOCK);
        vm.expectRevert(IBuybackBurnSink.NotSelf.selector);
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
        vm.expectRevert(abi.encodeWithSelector(IBuybackBurnSink.LaunchDoesNotTrade.selector, SAI_LAUNCH, pre2eCurrency));
        sink.convert(pre2eCurrency, SAI_LAUNCH);

        // AFTER. One owner call, naming a venue rather than a destination.
        vm.prank(TIMELOCK);
        sink.setQuoteRoute(Currency.wrap(address(sai)), saiQuotePool, UNBOUND_DEPTH);

        IBuybackBurnSink.Route memory route = sink.conversionRoute(pre2eCurrency, SAI_LAUNCH);
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
        emit IBuybackBurnSink.Parked(saiCurrency, 500 ether, 6);
        sink.burn(saiCurrency, 0);
        assertEq(sai.balanceOf(address(sink)), 500 ether, "a parked tranche must stay put");

        vm.prank(TIMELOCK);
        sink.setQuoteRoute(saiCurrency, saiQuotePool, UNBOUND_DEPTH);

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
        vm.expectRevert(abi.encodeWithSelector(IBuybackBurnSink.RouteMissingLeg.selector, saiCurrency));
        sink.setQuoteRoute(saiCurrency, elsewhere, UNBOUND_DEPTH);

        // A pool that trades the right pair on a tier nobody has opened. It would install
        // cleanly and then park every tranche, so it is refused where the error names the cause.
        PoolKey memory unopened = _key(sai, quote, 3000);
        vm.prank(TIMELOCK);
        vm.expectRevert(IBuybackBurnSink.PoolNotInitialised.selector);
        sink.setQuoteRoute(saiCurrency, unopened, UNBOUND_DEPTH);

        // And neither leg of the buyback is a routable asset: they have their own paths.
        vm.startPrank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(IBuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(quote)))
        );
        sink.setQuoteRoute(Currency.wrap(address(quote)), saiQuotePool, UNBOUND_DEPTH);
        vm.expectRevert(
            abi.encodeWithSelector(IBuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(burnToken)))
        );
        sink.setQuoteRoute(Currency.wrap(address(burnToken)), saiQuotePool, UNBOUND_DEPTH);
        vm.stopPrank();
    }

    /// Only the owner can name a venue, and retiring one is an explicit call that emits.
    function test_onlyTheOwnerRoutes_andClearingRestoresTheRefusal() public {
        Currency saiCurrency = Currency.wrap(address(sai));

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        sink.setQuoteRoute(saiCurrency, saiQuotePool, UNBOUND_DEPTH);

        vm.prank(TIMELOCK);
        sink.setQuoteRoute(saiCurrency, saiQuotePool, UNBOUND_DEPTH);
        (,, bool found) = sink.quoteRoute(saiCurrency);
        assertTrue(found, "the route did not install");
        assertEq(sink.conversionRoute(Currency.wrap(address(pre2e)), SAI_LAUNCH).legs, 2, "two legs expected");

        PoolKey memory cleared;
        vm.prank(TIMELOCK);
        sink.setQuoteRoute(saiCurrency, cleared, 0);
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
        // 20 bps, deliberately BELOW every pool's sandwich bound here (0.3% on a guard-hooked
        // launch pool whose creator takes 7000, 1% on the hookless SAI route), so what binds is
        // the setting and its split - the thing this test is about - and not the fee cap.
        vm.startPrank(TIMELOCK);
        sink.setGuards(1 ether, 20, INTERVAL);
        sink.setQuoteRoute(Currency.wrap(address(sai)), saiQuotePool, UNBOUND_DEPTH);
        vm.stopPrank();

        // A one-leg conversion may walk its pool by the FULL 20 bps of price: 10 bps, or 1,000
        // pips, of sqrt price.
        uint160 memeBefore = _sqrtPrice(memePool);
        meme.mint(address(sink), 10_000_000 ether);
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);
        uint256 oneLegMovePips = _movePips(memeBefore, _sqrtPrice(memePool));

        // A two-leg conversion gets half of that per leg instead.
        uint160 launchBefore = _sqrtPrice(saiLaunchPool);
        uint160 routeBefore = _sqrtPrice(saiQuotePool);
        pre2e.mint(address(sink), 10_000_000 ether);
        sink.convert(Currency.wrap(address(pre2e)), SAI_LAUNCH);
        uint256 legOneMovePips = _movePips(launchBefore, _sqrtPrice(saiLaunchPool));
        uint256 legTwoMovePips = _movePips(routeBefore, _sqrtPrice(saiQuotePool));

        // `memePool` and `saiLaunchPool` are the same shape - same tier, same spacing, same seed -
        // and both are fed the same oversized tranche, so the two numbers are directly
        // comparable. That comparison IS the claim: the same setting gives a leg of a two-leg
        // route half of what it gives a one-leg conversion.
        assertApproxEqAbs(oneLegMovePips, 1000, 5, "a one-leg conversion should walk to its full allowance");
        assertApproxEqAbs(legOneMovePips, 500, 5, "leg one of two should get half the allowance");

        // Leg two's share is a CEILING, not a target: leg one stopped at its own bound, so what
        // reached the route pool may be too small to walk it all the way. What must hold is that
        // it could not have gone further even if it were.
        assertLe(legTwoMovePips, 505, "leg two exceeded its share of the allowance");
        assertLe(
            legOneMovePips + legTwoMovePips,
            oneLegMovePips + 5,
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
        sink.setQuoteRoute(Currency.wrap(address(sai)), saiQuotePool, UNBOUND_DEPTH);

        IBuybackBurnSink.Route memory route = sink.conversionRoute(Currency.wrap(address(sai)), SAI_LAUNCH);
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
        sink.setQuoteRoute(Currency.wrap(address(meme)), rival, UNBOUND_DEPTH);

        IBuybackBurnSink.Route memory route = sink.conversionRoute(Currency.wrap(address(meme)), MEME_LAUNCH);
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
            vm.expectRevert(abi.encodeWithSelector(IBuybackBurnSink.ImpactBpsTooLow.selector, bps, floor));
            sink.setGuards(1 ether, bps, INTERVAL);
        }
        sink.setGuards(1 ether, floor, INTERVAL); // the floor itself is fine
        vm.stopPrank();
        assertEq(sink.maxImpactBps(), floor);
    }

    /// D20 is answered by the rate limit, so the rate limit is not optional.
    function test_aRateLimitOfZeroIsRefused() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(IBuybackBurnSink.RateLimitRequired.selector);
        sink.setGuards(1 ether, 500, 0);
    }

    /// Both legs being right does not make the pool exist. A key on an unopened tier used to
    /// install cleanly and then park every tranche silently.
    function test_setBuybackLaunchRejectsAPoolThatWasNeverInitialised() public {
        PoolKey memory ghost = _key(quote, burnToken, 3000); // same legs, a tier nobody opened
        _lock(77, 77, ghost);
        vm.prank(TIMELOCK);
        vm.expectRevert(IBuybackBurnSink.PoolNotInitialised.selector);
        sink.setBuybackLaunch(77);
    }

    // ── the floor: the whole differentiator ───────────────────────────────

    function test_burnBpsCannotBeLoweredPastTheFloor() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IBuybackBurnSink.BurnBpsBelowFloor.selector, uint16(7999), FLOOR));
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

        vm.expectRevert(abi.encodeWithSelector(IBuybackBurnSink.BurnBpsBelowFloor.selector, uint16(0), FLOOR));
        sink.setBurnBps(0);
        vm.stopPrank();
    }

    function test_constructorRejectsABurnShareUnderItsOwnFloor() public {
        vm.expectRevert(abi.encodeWithSelector(IBuybackBurnSink.BurnBpsBelowFloor.selector, uint16(5000), FLOOR));
        deployBuybackBurnSink(
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
            abi.encodeWithSelector(IBuybackBurnSink.CannotSweepBuybackLeg.selector, Currency.wrap(address(quote)))
        );
        sink.sweep(Currency.wrap(address(quote)), TIMELOCK);

        vm.expectRevert(
            abi.encodeWithSelector(IBuybackBurnSink.CannotSweepBuybackLeg.selector, Currency.wrap(address(burnToken)))
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
            abi.encodeWithSelector(IBuybackBurnSink.SweepRequiresHold.selector, Currency.wrap(address(meme)))
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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        sink.setOperator(STRANGER, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        sink.setMaxBuybackAmount(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        sink.setBuybackLaunch(BURN_LAUNCH);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        sink.setQuoteRoute(Currency.wrap(address(sai)), saiQuotePool, 1);
        vm.stopPrank();
    }

    /// A launch whose pool does not hold the burn token at all is a wrong id, and one whose pool
    /// pairs it against anything but the quote would park revenue silently forever.
    function test_setBuybackLaunchRejectsALaunchThatDoesNotTradeThePair() public {
        vm.startPrank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBuybackBurnSink.LaunchDoesNotTrade.selector, MEME_LAUNCH, Currency.wrap(address(burnToken))
            )
        );
        sink.setBuybackLaunch(MEME_LAUNCH);
        vm.expectRevert(
            abi.encodeWithSelector(IBuybackBurnSink.LaunchDoesNotTrade.selector, 404, Currency.wrap(address(burnToken)))
        );
        sink.setBuybackLaunch(404);
        vm.stopPrank();

        PoolKey memory saiPaired = _pairKey(MockERC20(address(burnToken)), sai, FEE);
        _seed(saiPaired, 1_000 ether);
        _lock(78, 78, saiPaired);
        vm.prank(TIMELOCK);
        vm.expectRevert(IBuybackBurnSink.PoolMissingLeg.selector);
        sink.setBuybackLaunch(78);
    }

    /// The key, the direction, the anchor and the creator's LP share all come off the locked
    /// position. Nobody types them.
    function test_setBuybackLaunchReadsEverythingOffTheLockedPosition() public view {
        bool quoteIsFirst = address(quote) < address(burnToken);
        assertEq(sink.quoteIsCurrency0(), quoteIsFirst, "swap direction was derived wrongly");
        assertEq(sink.buybackLaunchId(), BURN_LAUNCH);
        assertEq(sink.buybackAnchor(), BURN_POSITION, "the anchor is not the burn token's locked position");
        assertEq(sink.buybackLpCreatorBps(), 7000, "the creator's share was not read off the locker");
        (Currency c0, Currency c1,,,,) = sink.buybackPool();
        assertEq(Currency.unwrap(c0), Currency.unwrap(pool.currency0));
        assertEq(Currency.unwrap(c1), Currency.unwrap(pool.currency1));
    }

    // ── the lock callback ─────────────────────────────────────────────────

    function test_lockAcquiredRejectsANonVaultCaller() public {
        vm.prank(STRANGER);
        vm.expectRevert(IBuybackBurnSink.NotVault.selector);
        sink.lockAcquired(abi.encode(uint256(1)));
    }

    /// Gated on a lock THIS contract opened, not merely on the vault's identity.
    function test_lockAcquiredRejectsTheVaultOutsideAnOpenLock() public {
        vm.prank(address(vault));
        vm.expectRevert(IBuybackBurnSink.LockNotOpen.selector);
        sink.lockAcquired(abi.encode(uint256(1)));
    }

    function test_transientSlotMatchesItsDerivation() public pure {
        uint256 derived = uint256(keccak256("choice.v2.buybackburnsink.lockOpen")) - 1;
        assertEq(derived, 0xbb393ca8346e746397cbb72e3dd898fcb21e70d8c1e3b5ee10773bc10d26776e, "slot literal drifted");
    }

    // ── helpers ───────────────────────────────────────────────────────────

    // ---------------------------------------------------------------------------------------
    // Quote hops are REGISTERED, never derived.
    //
    // 1.5.0 derived a hop when nothing was registered: the deepest initialised hookless
    // `{asset, QUOTE}` pool across five standard tiers. `CLPoolManager.initialize` is
    // permissionless with no liquidity floor, so a hookless key is exactly the one anybody can
    // open at any price - and the sink swapped its WHOLE balance through whatever it found.
    // These pin the closure: a route the owner did not register does not exist.

    /// ⛔ The item itself. `sai` has a real, deep, hookless `{sai, QUOTE}` pool on a standard
    /// tier - the very thing 1.5.0 searched for and found. Nothing is registered for it, so it
    /// must be unroutable, and `burn` must park rather than sell.
    function test_anUnregisteredQuoteAssetIsUnroutableEvenWithADeepStandardTierPool() public {
        posm.setPoolManager(address(manager));
        IBuybackBurnSink fresh = _freshSink();

        // The pool 1.5.0 would have chosen really is there, and really is deep.
        assertTrue(_sqrtPrice(saiQuotePool) != 0, "the standard-tier pool should exist");

        (,, bool found) = fresh.quoteRoute(Currency.wrap(address(sai)));
        assertFalse(found, "an unregistered asset must have no route, however deep its pool");

        _configure(fresh);
        sai.mint(address(fresh), 500 ether);

        vm.expectEmit(true, false, false, true, address(fresh));
        emit IBuybackBurnSink.Parked(Currency.wrap(address(sai)), 500 ether, 6);
        fresh.burn(Currency.wrap(address(sai)), 0);

        assertEq(sai.balanceOf(address(fresh)), 500 ether, "an unregistered asset must not be sold");
    }

    /// ⛔ The attack 1.5.0 was open to, planted in full. `stray` has no legitimate market, so an
    /// attacker's hookless pool would have been the ONLY candidate and would have won outright -
    /// at a price they chose, with a position they could pull. `maxImpactBps` is no help: it is
    /// measured against this pool's own spot.
    ///
    /// The invariant is not "the derived key carries no hook" - that was never the threat, and
    /// the key below has no hook. It is that an UNREGISTERED asset routes NOWHERE.
    function test_theSinkRefusesAJitPricedHooklessPoolAnAttackerOpened() public {
        posm.setPoolManager(address(manager));
        IBuybackBurnSink fresh = _freshSink();
        _configure(fresh);

        // The attacker opens the pool the sink would have derived: currencies sorted, hooks
        // ZERO, this manager, a standard tier - a key the old `_deriveQuoteHop` built itself.
        PoolKey memory jit = _key(stray, quote, FEE);
        _seedAt(jit, JIT_SQRT_PRICE, JIT_TICK_LOWER, JIT_TICK_UPPER, 1e18);

        (,, bool found) = fresh.quoteRoute(Currency.wrap(address(stray)));
        assertFalse(found, "a pool anyone can open must never become a route");

        uint160 attackerSpotBefore = _sqrtPrice(jit);

        stray.mint(address(fresh), 100_000 ether);
        fresh.burn(Currency.wrap(address(stray)), 0);

        assertEq(stray.balanceOf(address(fresh)), 100_000 ether, "the balance must stay in the sink");
        assertEq(_sqrtPrice(jit), attackerSpotBefore, "not one wei may reach the attacker's pool");
    }

    /// ⛔ The second half of the finding. `convert` takes a launch id as a HINT, and an unknown
    /// id resolves to "not found" rather than reverting - so under 1.5.0 `convert(anything, 0)`
    /// fell through to the derived hop and reached the LAUNCH-TOKEN revenue stream, bypassing
    /// both the hint and the `PARK_NEEDS_HINT` park. With no derivation there is nothing to fall
    /// through to, and the bad hint is reported as one.
    function test_convertWithAnUnknownLaunchIdCannotBypassTheHint() public {
        posm.setPoolManager(address(manager));
        IBuybackBurnSink fresh = _freshSink();
        _configure(fresh);

        // A hookless pool for the launch token, exactly as an attacker would leave it.
        PoolKey memory planted = _key(meme, quote, FEE);
        _seedAt(planted, JIT_SQRT_PRICE, JIT_TICK_LOWER, JIT_TICK_UPPER, 1e18);

        meme.mint(address(fresh), 1_000 ether);

        uint256 unknownLaunch = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                IBuybackBurnSink.LaunchDoesNotTrade.selector, unknownLaunch, Currency.wrap(address(meme))
            )
        );
        fresh.convert(Currency.wrap(address(meme)), unknownLaunch);

        assertEq(meme.balanceOf(address(fresh)), 1_000 ether, "a bad hint must move nothing");
    }

    /// Governance names the VENUE, and depth does not argue with it. A registered route on a
    /// thin tier is used even though a deeper pool for the same pair sits one tier away - the
    /// opposite of 1.5.0, which picked by liquidity and so could be outbid.
    function test_aRegisteredRouteIsTheOnlyRouteEvenWhenAnotherTierIsDeeper() public {
        posm.setPoolManager(address(manager));
        IBuybackBurnSink fresh = _freshSink();

        PoolKey memory thin = _key(sai, quote, OLD_FEE);
        _seed(thin, 5_000 ether); // saiQuotePool at FEE is seeded 500_000 - a hundredfold deeper

        vm.prank(TIMELOCK);
        fresh.setQuoteRoute(Currency.wrap(address(sai)), thin, UNBOUND_DEPTH);

        (PoolKey memory used,, bool found) = fresh.quoteRoute(Currency.wrap(address(sai)));
        assertTrue(found, "the registered route should resolve");
        assertEq(used.fee, OLD_FEE, "the registered route must win, not the deeper pool");
    }

    /// 🔑 `quoteRoute` and `registeredQuoteRoute` now answer identically, by construction. The
    /// day they disagree is the day an unregistered asset has become routable again, which is
    /// the whole of this fix - so the identity is asserted rather than assumed.
    function test_theTwoRouteViewsCannotDisagree() public {
        posm.setPoolManager(address(manager));
        IBuybackBurnSink fresh = _freshSink();

        Currency[] memory assets = new Currency[](3);
        assets[0] = Currency.wrap(address(sai)); // deep standard-tier pool, unregistered
        assets[1] = Currency.wrap(address(stray)); // no pool at all
        assets[2] = Currency.wrap(address(meme)); // a launch token

        for (uint256 i; i < assets.length; ++i) {
            _assertViewsAgree(fresh, assets[i]);
        }

        vm.prank(TIMELOCK);
        fresh.setQuoteRoute(Currency.wrap(address(sai)), saiQuotePool, UNBOUND_DEPTH);
        for (uint256 i; i < assets.length; ++i) {
            _assertViewsAgree(fresh, assets[i]);
        }
    }

    function _assertViewsAgree(IBuybackBurnSink s, Currency asset) internal view {
        (PoolKey memory effective, bool effectiveFirst, bool effectiveFound) = s.quoteRoute(asset);
        (PoolKey memory pinned, bool pinnedFirst, bool pinnedFound) = s.registeredQuoteRoute(asset);
        assertEq(effectiveFound, pinnedFound, "effective and pinned must agree on existence");
        assertEq(effectiveFirst, pinnedFirst, "and on direction");
        assertEq(PoolId.unwrap(effective.toId()), PoolId.unwrap(pinned.toId()), "and on the pool");
    }

    /// An asset with no pool at all stays unroutable, and `burn` still parks rather than reverts.
    function test_anAssetWithNoPoolAnywhereStaysUnroutable() public {
        posm.setPoolManager(address(manager));
        IBuybackBurnSink fresh = _freshSink();

        (,, bool found) = fresh.quoteRoute(Currency.wrap(address(stray)));
        assertFalse(found, "a currency with no pool and no route is unroutable");

        _configure(fresh);
        stray.mint(address(fresh), 100 ether);
        fresh.burn(Currency.wrap(address(stray)), 0);
        assertEq(stray.balanceOf(address(fresh)), 100 ether, "it should park, not revert");
    }

    // ── 1.7.0: the sandwich bound ─────────────────────────────────────────

    /// 🔴 **The 2026-09-30 finding.** Anyone may call `buyback()`, and 1.6.0 bounded its impact
    /// against the spot price in the SAME transaction. So one transaction could pump the pool,
    /// call `buyback()`, and dump. A pump also raised what the sink was allowed to spend, so the
    /// sink spent its whole backlog at the top. The fixture's own guard, 500 bps, is the setting
    /// that was exploitable; this runs the attack at every pump size up to ~6x the pool's depth.
    ///
    /// Under 1.7.0 each buyback may move the price by at most the pool's unrecoverable fee, and
    /// the attacker pays that fee twice to earn the move once. So it never pays.
    function testFuzz_anAtomicSandwichOfThePublicBuybackNeverPays(uint96 rawPump) public {
        uint256 pump = bound(uint256(rawPump), 1_000 ether, 3_000_000 ether);
        // A backlog far larger than one window can spend: what the fallback path would face after
        // an operator outage, and the balance that made 1.6.0 worth attacking.
        quote.mint(address(sink), 200_000 ether);

        quote.mint(address(this), pump);
        uint256 quoteBefore = quote.balanceOf(address(this));
        uint256 tokensBefore = burnToken.balanceOf(address(this));

        bool buyZeroForOne = Currency.unwrap(pool.currency0) == address(quote);
        uint256 bought = _attackerSwap(pool, buyZeroForOne, pump);
        sink.buyback();
        _attackerSwap(pool, !buyZeroForOne, bought);

        assertEq(burnToken.balanceOf(address(this)), tokensBefore, "the attacker kept tokens");
        assertLe(quote.balanceOf(address(this)), quoteBefore, "the sandwich paid");
    }

    /// The bound holds whatever `maxImpactBps` says. The fixture allows 500 bps; the pool's fee
    /// is 1%, all of it unrecoverable on a hookless pool, so the move stops at 1% of price: 0.5%,
    /// or 5,000 pips, of sqrt price. And the swap is sized to reach that limit rather than
    /// offered the whole balance, so the rest is never put to the pool at all.
    function test_theFeeCapBindsWhenTheGuardIsLooser() public {
        uint160 before = _sqrtPrice(pool);
        quote.mint(address(sink), 500_000 ether);

        sink.buyback();

        // Sized to land just SHORT of the limit (`_fillableInput` rounds down), and never past it.
        uint256 moved = _movePips(before, _sqrtPrice(pool));
        assertLe(moved, 5000, "the move went past the fee bound");
        assertGe(moved, 4990, "the swap was sized well short of its limit");
        assertGt(quote.balanceOf(address(sink)), 0, "the cap did not bind");
    }

    /// And a launch pool whose creator takes the WHOLE LP fee has nothing unrecoverable left, so
    /// its creator could sandwich any nonzero bound. The bound is zero, the conversion parks as a
    /// failed swap, and no window is spent.
    function test_aLaunchPoolWhoseCreatorTakesTheWholeFeeNeverConverts() public {
        MockERC20 greedy = new MockERC20("Greedy", "GREEDY", 18);
        PoolKey memory greedyPool = _graduationKey(greedy, FEE);
        _seed(greedyPool, 1_000_000 ether);
        posm.setPool(9, greedyPool);
        locker.registerWithShare(99, 9, 10_000);
        greedy.mint(address(sink), 100 ether);

        vm.expectEmit(true, false, false, true, address(sink));
        emit IBuybackBurnSink.Parked(Currency.wrap(address(greedy)), 100 ether, 3);
        sink.convert(Currency.wrap(address(greedy)), 99);

        assertEq(greedy.balanceOf(address(sink)), 100 ether, "the tranche moved");
        assertEq(sink.lastConvertAt(Currency.wrap(address(greedy))), 0, "a refused swap spent the window");
    }

    /// What the operator's keeper reads to price a tranche: on a hookless 1% pool, the whole fee
    /// is the pool manager's and all of it is unrecoverable.
    function test_previewBuybackReportsTheOfferAndThePoolsFees() public {
        quote.mint(address(sink), 50 ether);
        vm.prank(TIMELOCK);
        sink.setMaxBuybackAmount(20 ether);

        (uint256 offer, uint160 sqrtPriceX96, uint128 liquidity, uint256 swapFee, uint256 hookFee, uint256 bound_) =
            sink.previewBuyback();

        assertEq(offer, 20 ether, "the offer ignores the tranche cap");
        assertEq(sqrtPriceX96, _sqrtPrice(pool));
        assertGt(liquidity, 0);
        assertEq(swapFee, FEE);
        assertEq(hookFee, 0);
        assertEq(bound_, FEE);
    }

    // ── 1.7.0: the operator and the fallback ──────────────────────────────

    function test_onlyTheOperatorRunsTheScheduledBuyback() public {
        _appoint(6 hours);
        quote.mint(address(sink), 100 ether);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IBuybackBurnSink.NotOperator.selector, STRANGER));
        sink.operatorBuyback(100 ether, 1);

        vm.prank(OPERATOR);
        (uint256 spent, uint256 received) = sink.operatorBuyback(100 ether, 1);
        assertGt(spent, 0);
        assertGt(received, 0);
        assertEq(sink.lastOperatorBuybackAt(), block.timestamp);
    }

    /// While the operator is live the permissionless path PARKS (reason 7), because `harvest`
    /// and the cranker both reach it and neither may revert. After `publicFallbackDelay` without
    /// an operator fill it reopens: the burn never depends on the keeper staying up.
    function test_aLiveOperatorHoldsThePublicBuybackUntilTheFallbackOpens() public {
        _appoint(6 hours);
        quote.mint(address(sink), 100 ether);

        vm.expectEmit(true, false, false, true, address(sink));
        emit IBuybackBurnSink.Parked(Currency.wrap(address(quote)), 100 ether, 7);
        sink.burn(Currency.wrap(address(quote)), 100 ether);
        assertEq(quote.balanceOf(address(sink)), 100 ether, "the public path ran past a live operator");
        assertFalse(sink.canBuyback());
        assertEq(sink.publicBuybackOpensAt(), block.timestamp + 6 hours);

        vm.warp(block.timestamp + 6 hours);
        assertTrue(sink.canBuyback());
        sink.buyback();
        assertLt(quote.balanceOf(address(sink)), 100 ether, "the fallback did not reopen");
    }

    /// Only a real FILL moves the clock, so an operator that runs but never trades cannot hold the
    /// fallback shut for ever.
    function test_anOperatorFillRestartsTheFallbackClock() public {
        _appoint(6 hours);
        quote.mint(address(sink), 100 ether);

        vm.warp(block.timestamp + 5 hours);
        vm.prank(OPERATOR);
        sink.operatorBuyback(10 ether, 1);

        vm.warp(block.timestamp + 2 hours); // 7h since appointment, 2h since the fill
        uint256 held = quote.balanceOf(address(sink));
        sink.buyback();
        assertEq(quote.balanceOf(address(sink)), held, "the fallback opened 2h after a fill");

        vm.warp(block.timestamp + 4 hours);
        sink.buyback();
        assertLt(quote.balanceOf(address(sink)), held, "the fallback never reopened");
    }

    /// The operator's minimum is what refuses a spike, which no bound measured against spot can
    /// do. A miss REVERTS, and nothing moves.
    function test_theOperatorsMinimumRateRefusesABadPrice() public {
        _appoint(6 hours);
        quote.mint(address(sink), 100 ether);
        uint256 supplyBefore = burnToken.totalSupply();

        // The pool is 1:1, so two tokens per wINJ cannot be had.
        vm.prank(OPERATOR);
        vm.expectRevert();
        sink.operatorBuyback(100 ether, 2e18);
        assertEq(quote.balanceOf(address(sink)), 100 ether, "a refused buyback spent");
        assertEq(burnToken.totalSupply(), supplyBefore);

        // 0.95 per wINJ allows the 1% fee and the price walk, and it holds.
        vm.prank(OPERATOR);
        (uint256 spent, uint256 received) = sink.operatorBuyback(100 ether, 0.95e18);
        assertGe(received * 1e18, spent * 0.95e18, "the minimum was not enforced");
    }

    /// 🔑 A stolen operator key buys nothing: the operator is held to the same fee bound as
    /// everyone, so it cannot move the pool far enough to profit from sandwiching its own call.
    function test_theOperatorIsHeldToTheSameFeeBound() public {
        _appoint(6 hours);
        vm.prank(TIMELOCK);
        sink.setGuards(1 ether, 5000, INTERVAL); // 50%: as loose as the owner could make it
        uint160 before = _sqrtPrice(pool);
        quote.mint(address(sink), 500_000 ether);

        vm.prank(OPERATOR);
        sink.operatorBuyback(type(uint256).max, 1);

        assertLe(_movePips(before, _sqrtPrice(pool)), 5005, "the operator moved the pool past the fee");
    }

    /// The TWAP tranche binds both paths, so no single call commits the whole backlog.
    function test_theTrancheCapBoundsBothPaths() public {
        vm.prank(TIMELOCK);
        sink.setMaxBuybackAmount(10 ether);
        quote.mint(address(sink), 100 ether);

        sink.buyback();
        // 10 spent, plus the 2.5 ops share that spend earned.
        assertEq(quote.balanceOf(address(sink)), 87.5 ether, "the public path spent past the tranche");

        _appoint(6 hours);
        vm.warp(block.timestamp + INTERVAL); // 1.8.0: one window for both paths
        vm.prank(OPERATOR);
        (uint256 spent,) = sink.operatorBuyback(type(uint256).max, 1);
        assertEq(spent, 10 ether, "the operator spent past the tranche");
    }

    // ── 1.8.0: the 2026-10-01 audit's §4.1, and ops in quote ──────────────

    /// F1, the attack itself, on the permissionless buyback. Pump the buyback pool, open a
    /// one-band position at the top, trigger the buyback, pull the position, unwind, and buy
    /// back whatever burn token moved. Under 1.7.0 the sink sized its swap from the pool's
    /// in-range liquidity, which included the band, so it spent its whole tranche at the
    /// attacker's price while barely moving it. 1.8.0 sizes against the burn token's LOCKED
    /// position, so the band only makes the swap move less. It never makes it bigger.
    ///
    /// Run against 1.7.0 (same pool, same backlog, 1.7.0's setters) this nets the attacker
    /// tens of thousands of quote across the range. See the PR body.
    function testFuzz_aJitSandwichOfThePublicBuybackNeverPays(uint96 rawPump) public {
        uint256 pump = bound(uint256(rawPump), 10_000 ether, 3_000_000 ether);
        _anchorAtTheSeed(BURN_POSITION, pool);
        quote.mint(address(sink), 200_000 ether);

        bool buyZeroForOne = Currency.unwrap(pool.currency0) == address(quote);
        int256 pnl = _jitSandwich(pool, MockERC20(address(burnToken)), buyZeroForOne, pump, _triggerBuyback);

        assertGt(sink.lastBuybackAt(), 0, "the buyback never ran, so this proves nothing");
        assertLe(pnl, 0, "the JIT sandwich paid");
    }

    /// F1 on the conversion path, which 1.7.0 left with no tranche cap at all. The attacker
    /// DUMPS the launch token, opens a band below, and the sink sells its launch-token revenue
    /// into it. The launch's own locked position is the anchor.
    function testFuzz_aJitSandwichOfAConversionNeverPays(uint96 rawPump) public {
        uint256 pump = bound(uint256(rawPump), 10_000 ether, 3_000_000 ether);
        _anchorAtTheSeed(1, memePool);
        meme.mint(address(sink), 200_000 ether);

        bool sellZeroForOne = Currency.unwrap(memePool.currency0) == address(meme);
        int256 pnl = _jitSandwich(memePool, meme, sellZeroForOne, pump, _triggerConvert);

        assertGt(sink.lastConvertAt(Currency.wrap(address(meme))), 0, "the conversion never ran");
        assertLe(pnl, 0, "the JIT sandwich paid");
    }

    /// The anchor counts only while its range covers the whole walk. A position the price has
    /// left would leave the in-range liquidity entirely to whoever put it there, so it sizes
    /// nothing and the tranche parks as a failed swap.
    function test_anAnchorTheWalkWouldLeaveSizesNothing() public {
        posm.setPosition(BURN_POSITION, pool, 200, 400, 500_000 ether); // above spot, out of range
        quote.mint(address(sink), 100 ether);

        vm.expectEmit(true, false, false, true, address(sink));
        emit IBuybackBurnSink.Parked(Currency.wrap(address(quote)), 80 ether, 3);
        sink.buyback();
        assertEq(sink.lastBuybackAt(), 0, "a failed swap spent the window");
    }

    /// And a position in some OTHER pool is no anchor for this one, whatever its liquidity.
    function test_anAnchorInAnotherPoolSizesNothing() public {
        posm.setPosition(BURN_POSITION, pool, -887_200, 887_200, 500_000 ether);
        vm.prank(TIMELOCK);
        sink.setBuybackLaunch(BURN_LAUNCH); // reads the key and the anchor afresh
        posm.setPosition(BURN_POSITION, memePool, -887_200, 887_200, 500_000 ether); // moved under it
        quote.mint(address(sink), 100 ether);

        sink.buyback();
        assertEq(sink.lastBuybackAt(), 0, "a foreign position sized the swap");
    }

    /// F2. A stolen operator key used to be able to call `operatorBuyback` again and again in one
    /// transaction and walk the price a fee-cap per call. It now gets one fill per window,
    /// shared with the public path.
    function test_theOperatorGetsOneFillPerWindow() public {
        _appoint(6 hours);
        quote.mint(address(sink), 1_000 ether);

        vm.startPrank(OPERATOR);
        sink.operatorBuyback(10 ether, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IBuybackBurnSink.RateLimited.selector, block.timestamp + uint256(INTERVAL))
        );
        sink.operatorBuyback(10 ether, 1);

        vm.warp(block.timestamp + INTERVAL);
        sink.operatorBuyback(10 ether, 1);
        vm.stopPrank();
    }

    /// F2. An operator must name the least it will accept. Zero used to mean "no check".
    function test_theOperatorMustNameAMinimumRate() public {
        _appoint(6 hours);
        quote.mint(address(sink), 100 ether);

        vm.prank(OPERATOR);
        vm.expectRevert(IBuybackBurnSink.MinimumRateRequired.selector);
        sink.operatorBuyback(100 ether, 0);
    }

    /// F2. A dust fill does not restart the fallback clock, so an operator - or whoever holds its
    /// key - cannot keep the public path shut by buying a wei every few hours.
    function test_aDustOperatorFillDoesNotHoldTheFallbackShut() public {
        _appoint(6 hours);
        quote.mint(address(sink), 100 ether);
        // Read off the contract, not `block.timestamp`: via-IR sinks that read past `vm.warp`.
        uint256 opensAt = sink.publicBuybackOpensAt();

        vm.warp(block.timestamp + 5 hours);
        vm.prank(OPERATOR);
        (uint256 spent,) = sink.operatorBuyback(0.5 ether, 1); // under the 1 wINJ minimum
        assertGt(spent, 0, "the dust fill did not trade");
        assertEq(sink.lastOperatorBuybackAt(), 0, "a dust fill moved the fallback clock");
        assertEq(sink.publicBuybackOpensAt(), opensAt, "the fallback moved");
    }

    /// The tranche cap is mandatory (F1). Until one is set, nothing trades on any path, and zero
    /// can never be set as one.
    function test_withoutATrancheCapNothingTrades() public {
        IBuybackBurnSink fresh = _freshSink();
        vm.startPrank(TIMELOCK);
        fresh.setLockers(_one(address(locker)));
        fresh.setBuybackLaunch(BURN_LAUNCH);
        fresh.setGuards(1 ether, 500, INTERVAL);
        fresh.setOperator(OPERATOR, 6 hours);
        vm.expectRevert(IBuybackBurnSink.TrancheCapRequired.selector);
        fresh.setMaxBuybackAmount(0);
        fresh.setOperator(address(0), 0);
        vm.stopPrank();

        quote.mint(address(fresh), 100 ether);
        meme.mint(address(fresh), 100 ether);
        assertFalse(fresh.canBuyback(), "an uncapped sink reports it can trade");

        vm.expectEmit(true, false, false, true, address(fresh));
        emit IBuybackBurnSink.Parked(Currency.wrap(address(quote)), 100 ether, 8);
        fresh.burn(Currency.wrap(address(quote)), 100 ether);

        vm.expectEmit(true, false, false, true, address(fresh));
        emit IBuybackBurnSink.Parked(Currency.wrap(address(meme)), 100 ether, 8);
        fresh.convert(Currency.wrap(address(meme)), MEME_LAUNCH);

        vm.prank(TIMELOCK);
        fresh.setOperator(OPERATOR, 6 hours);
        vm.prank(OPERATOR);
        vm.expectRevert(IBuybackBurnSink.NothingToBuyBack.selector);
        fresh.operatorBuyback(100 ether, 1);

        assertEq(quote.balanceOf(address(fresh)), 100 ether, "quote moved");
        assertEq(meme.balanceOf(address(fresh)), 100 ether, "the launch token moved");
    }

    /// F1. A conversion is worth at most `maxBuybackAmount` of quote at the route's spot. The
    /// pools are 1:1, so a 10 wINJ cap sells ~10 of the launch token, and the rest waits.
    function test_aConversionIsCappedAtTheTranchesWorthOfQuote() public {
        vm.prank(TIMELOCK);
        sink.setMaxBuybackAmount(10 ether);
        meme.mint(address(sink), 100 ether);

        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);

        uint256 sold = 100 ether - meme.balanceOf(address(sink));
        assertGt(sold, 9.9 ether, "the cap sold far less than it allows");
        assertLe(sold, 10.01 ether, "the conversion sold past the tranche's worth");
    }

    /// F1 on a registered route: no locked position exists, so the depth named with the route is
    /// what a conversion is sized against, and a route must name one.
    function test_aQuoteRouteIsSizedByTheDepthNamedWithIt() public {
        Currency saiCurrency = Currency.wrap(address(sai));
        vm.prank(TIMELOCK);
        vm.expectRevert(IBuybackBurnSink.DepthRequired.selector);
        sink.setQuoteRoute(saiCurrency, saiQuotePool, 0);

        // A shallow ceiling: a hundredth of the pool's real liquidity.
        vm.prank(TIMELOCK);
        sink.setQuoteRoute(saiCurrency, saiQuotePool, 2_500 ether);
        assertEq(sink.quoteRouteDepth(saiCurrency), 2_500 ether);
        sai.mint(address(sink), 10_000 ether);

        sink.burn(saiCurrency, 10_000 ether);

        // 1% fee, so a 0.5% sqrt walk; on liquidity 2,500 that is ~12.6 SAI.
        uint256 sold = 10_000 ether - sai.balanceOf(address(sink));
        assertGt(sold, 0, "nothing converted");
        assertLt(sold, 13 ether, "the conversion was sized past the route's ceiling");
    }

    /// The ops share is `1 - burnBps` of revenue, paid in quote, at whatever `burnBps` is, and the
    /// sink never holds less quote than it owes.
    function testFuzz_theOpsShareIsTheRestOfRevenueInQuote(uint16 rawBps, uint96 rawRevenue) public {
        uint16 bps = uint16(bound(rawBps, FLOOR, 10_000));
        uint256 revenue = bound(uint256(rawRevenue), 2 ether, 4_000 ether);
        vm.prank(TIMELOCK);
        sink.setBurnBps(bps);
        quote.mint(address(sink), revenue);

        sink.buyback();

        uint256 paid = quote.balanceOf(TREASURY);
        uint256 spent = revenue - paid - quote.balanceOf(address(sink));
        assertEq(paid, spent * (10_000 - bps) / bps, "ops is not the rest of revenue");
        assertLe(spent, revenue * bps / 10_000, "the buyback spent past its share");
        assertGe(quote.balanceOf(address(sink)), sink.treasuryOwed(), "owed more than held");
        assertEq(burnToken.balanceOf(TREASURY), 0, "ops was paid in the burn token");
    }

    function _appoint(uint32 delay) internal {
        vm.prank(TIMELOCK);
        sink.setOperator(OPERATOR, delay);
    }

    /// Make a locked position REAL for the anchoring tests: full range, holding exactly the
    /// liquidity `_seed` put in the pool. `setPool` gives one that never binds.
    function _anchorAtTheSeed(uint256 tokenId, PoolKey memory key) internal {
        posm.setPosition(tokenId, key, -887_200, 887_200, uint128(manager.getLiquidity(key.toId())));
    }

    function _triggerBuyback() internal {
        sink.buyback();
    }

    function _triggerConvert() internal {
        sink.convert(Currency.wrap(address(meme)), MEME_LAUNCH);
    }

    /// The audit's F1 attack, end to end, from one contract: move the pool by `pump`, open a
    /// three-band position around the new price, `trigger` the sink, pull the position, unwind
    /// the pump, then trade `token` back to exactly the balance it started at.
    /// @return pnl What the attacker made in quote, with its `token` balance exactly restored.
    function _jitSandwich(
        PoolKey memory key,
        MockERC20 token,
        bool pumpZeroForOne,
        uint256 pump,
        function() internal trigger
    ) internal returns (int256 pnl) {
        uint256 bankroll = 1_000_000_000 ether;
        quote.mint(address(this), pump + bankroll);
        token.mint(address(this), pump + bankroll);
        uint256 quoteBefore = quote.balanceOf(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));

        uint256 got = _attackerSwap(key, pumpZeroForOne, pump);

        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 lower = (tick >= 0 ? tick / SPACING : (tick - SPACING + 1) / SPACING) * SPACING - SPACING;
        int24 upper = lower + 3 * SPACING;
        _band(key, lower, upper, int256(100_000_000 ether));
        trigger();
        _band(key, lower, upper, -int256(100_000_000 ether));

        _attackerSwap(key, !pumpZeroForOne, got);

        bool tokenIs0 = Currency.unwrap(key.currency0) == address(token);
        uint256 held = token.balanceOf(address(this));
        if (held > tokenBefore) _attackerSwap(key, tokenIs0, held - tokenBefore);
        else if (held < tokenBefore) _attackerBuyExact(key, !tokenIs0, tokenBefore - held);
        assertEq(token.balanceOf(address(this)), tokenBefore, "the token balance was not restored");

        pnl = int256(quote.balanceOf(address(this))) - int256(quoteBefore);
    }

    function _band(PoolKey memory key, int24 lower, int24 upper, int256 delta) internal {
        seeder.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: delta, salt: bytes32(uint256(0x417))
            }),
            ""
        );
    }

    function _attackerBuyExact(PoolKey memory key, bool zeroForOne, uint256 amountOut) internal {
        seeder.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    /// The attacker is this test contract, trading through the seeder router at no price limit.
    function _attackerSwap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (uint256 received) {
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        MockERC20 out = MockERC20(Currency.unwrap(output));
        uint256 before = out.balanceOf(address(this));
        seeder.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
        received = out.balanceOf(address(this)) - before;
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
    function _configure(IBuybackBurnSink s) internal {
        vm.startPrank(TIMELOCK);
        s.setLockers(_one(address(locker)));
        s.setBuybackLaunch(BURN_LAUNCH);
        s.setGuards(1 ether, 500, INTERVAL);
        s.setMaxBuybackAmount(LOOSE_TRANCHE);
        vm.stopPrank();
    }

    function _freshSink() internal returns (IBuybackBurnSink) {
        return deployBuybackBurnSink(
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

    /// How far a pool's sqrt price moved, in pips (1e-6), either direction. The 1.7.0 bounds are
    /// fractions of a percent, below what whole basis points can resolve.
    function _movePips(uint160 before, uint160 present) internal pure returns (uint256) {
        uint256 diff = present > before ? present - before : before - present;
        return diff * 1_000_000 / uint256(before);
    }

    /// How far a pool's sqrt price moved, in basis points, either direction.
    function _moveBps(uint160 before, uint160 present) internal pure returns (uint256) {
        uint256 diff = present > before ? present - before : before - present;
        return diff * 10_000 / uint256(before);
    }

    /// A pool opened at a price of the opener's choosing, with a NARROW position behind it -
    /// the shape of the attack `_deriveQuoteHop` was open to. `CLPoolManager.initialize` is
    /// permissionless and has no liquidity floor, so the price, the range and the depth are all
    /// the opener's to pick, and a one-band position is cheap to place and cheap to pull.
    ///
    /// 🔑 Narrow rather than full-range because at a price this far from 1:1 a full-range
    /// position would demand an absurd amount of one side - which is the honest reason an
    /// attacker would place exactly this shape.
    function _seedAt(PoolKey memory key, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
    {
        manager.initialize(key, sqrtPriceX96);
        MockERC20(Currency.unwrap(key.currency0)).mint(address(this), type(uint128).max);
        MockERC20(Currency.unwrap(key.currency1)).mint(address(this), type(uint128).max);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(seeder), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(seeder), type(uint256).max);
        seeder.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
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
