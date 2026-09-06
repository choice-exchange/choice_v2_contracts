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

import {BuybackBurnSink} from "../src/fees/BuybackBurnSink.sol";
import {LaunchPoolGuardHook} from "../src/launchpad/LaunchPoolGuardHook.sol";
import {IBurnableERC20} from "../src/interfaces/IBurnableERC20.sol";
import {MockBurnableERC20} from "./mocks/MockBurnableERC20.sol";

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

    Vault internal vault;
    CLPoolManager internal manager;
    CLPoolManagerRouter internal seeder;

    MockERC20 internal quote; // wINJ
    MockBurnableERC20 internal sprout; // SPROUT
    MockERC20 internal stray; // a currency with no pool anywhere

    /// A launch token that is NOT the burn token, which is the case §9.0's walk could not
    /// reach: its test launch token WAS SPROUT, so it hit the `BURN_TOKEN` arm and settled.
    MockERC20 internal meme;
    /// A second one, to show that one launch token's rate-limit window is its own.
    MockERC20 internal meme2;

    /// The real guard hook, because the derived conversion key is only trustworthy insofar as
    /// only a settler can open a pool at it. `address(this)` stands in for the settler.
    LaunchPoolGuardHook internal guardHook;

    BuybackBurnSink internal sink;
    PoolKey internal pool;
    PoolKey internal memePool;

    function setUp() public {
        vault = new Vault();
        manager = new CLPoolManager(vault);
        vault.registerApp(address(manager));
        seeder = new CLPoolManagerRouter(vault, manager);

        quote = new MockERC20("Wrapped INJ", "wINJ", 18);
        sprout = new MockBurnableERC20("Sprout", "SPROUT", 18);
        stray = new MockERC20("Stray", "STRAY", 18);
        meme = new MockERC20("Launch", "LAUNCH", 18);
        meme2 = new MockERC20("Launch Two", "LAUNCH2", 18);
        guardHook = new LaunchPoolGuardHook(address(this), address(this));

        sink = new BuybackBurnSink(
            IBurnableERC20(address(sprout)),
            Currency.wrap(address(quote)),
            IVault(address(vault)),
            TREASURY,
            TIMELOCK,
            FLOOR,
            FLOOR
        );

        pool = _key(quote, sprout, FEE);
        _seed(pool, 1_000_000 ether);

        // The graduation pool of a launch that is not SPROUT: same 1% tier, same spacing, keyed
        // to the guard hook. Deliberately thinner than the buyback pool - a graduate's seed is
        // whatever its curve filled, not a market-made book.
        memePool = _graduationKey(meme);
        _seed(memePool, 100_000 ether);

        vm.startPrank(TIMELOCK);
        sink.setBuybackPool(pool);
        sink.setConversionTier(IPoolManager(address(manager)), IHooks(address(guardHook)), FEE, _graduationParameters());
        // 1 wINJ minimum, 500 bps of sqrt-price headroom, one window per half hour. The rate
        // limit is not optional any more - `setGuards` refuses zero - so the fixture carries a
        // production-shaped value and tests that want a second buyback warp past it.
        sink.setGuards(1 ether, 500, INTERVAL);
        vm.stopPrank();
    }

    // ── the reason this contract exists ───────────────────────────────────

    /// The whole loop, end to end: revenue in quote becomes SPROUT, 80% of it is destroyed for
    /// real, and the ops share reaches the treasury.
    function test_revenueIsBoughtBackAndEightyPercentIsDestroyed() public {
        uint256 supplyBefore = sprout.totalSupply();
        quote.mint(address(sink), 100 ether);

        sink.burn(Currency.wrap(address(quote)), 100 ether);

        uint256 burnt = supplyBefore - sprout.totalSupply();
        uint256 toTreasury = sprout.balanceOf(TREASURY);
        uint256 bought = burnt + toTreasury;

        assertGt(bought, 0, "nothing was bought");
        assertEq(burnt, bought * FLOOR / 10_000, "burn share is not burnBps of what was bought");
        assertEq(toTreasury, bought - burnt, "treasury did not get the remainder");
        assertEq(sprout.balanceOf(address(sink)), 0, "SPROUT was left sitting in the sink");
        assertEq(quote.balanceOf(address(sink)), 0, "quote was left unspent");
    }

    /// The normalise leg (A4), which is the arm §9.0's walk could never reach: its launch token
    /// WAS SPROUT, so it settled directly. A launch token that is not the burn token used to
    /// park for ever; now it is sold for wINJ against its OWN graduation pool, and the proceeds
    /// go straight on to buy SPROUT and burn it - all in the one call `harvest` makes.
    function test_aLaunchTokenIsConvertedBoughtBackAndBurnt() public {
        uint256 supplyBefore = sprout.totalSupply();
        meme.mint(address(sink), 100 ether);

        sink.burn(Currency.wrap(address(meme)), 100 ether);

        uint256 burnt = supplyBefore - sprout.totalSupply();
        uint256 toTreasury = sprout.balanceOf(TREASURY);

        assertGt(burnt, 0, "the launch token parked instead of burning");
        assertEq(burnt, (burnt + toTreasury) * FLOOR / 10_000, "burn share is not burnBps of what was bought");
        assertEq(meme.balanceOf(address(sink)), 0, "the launch token was not fully converted");
        assertEq(quote.balanceOf(address(sink)), 0, "the wINJ it converted to was not spent");
        assertEq(sprout.balanceOf(address(sink)), 0, "SPROUT was left sitting in the sink");
    }

    /// `burn` is what `ChoiceFeeController.harvest` calls after transferring. If it can revert,
    /// a launch token with no pool bricks harvesting for that currency - so it must not. The
    /// derivation cannot find a pool for this one, because none was ever opened.
    function test_burnDoesNotRevertOnACurrencyWithNoPool() public {
        stray.mint(address(sink), 5 ether);

        vm.expectEmit(true, false, false, true, address(sink));
        emit BuybackBurnSink.Parked(Currency.wrap(address(stray)), 5 ether, 3);
        sink.burn(Currency.wrap(address(stray)), 5 ether);

        assertEq(stray.balanceOf(address(sink)), 5 ether, "unroutable funds should be held, not moved");
        assertEq(stray.balanceOf(TREASURY), 0, "ops must not receive what the burn was entitled to");
    }

    /// And a sink whose tier was never set has no route at all - it must park rather than
    /// revert, or wiring it in the wrong order would brick harvests until somebody noticed.
    function test_burnDoesNotRevertBeforeAConversionTierIsConfigured() public {
        BuybackBurnSink fresh = _freshSink();
        meme.mint(address(fresh), 100 ether);

        vm.expectEmit(true, false, false, true, address(fresh));
        emit BuybackBurnSink.Parked(Currency.wrap(address(meme)), 100 ether, 2);
        fresh.burn(Currency.wrap(address(meme)), 100 ether);

        assertEq(meme.balanceOf(address(fresh)), 100 ether, "funds should be held until a tier exists");
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
        assertGt(sprout.balanceOf(TREASURY), 0, "a partial fill still has to settle its burn");
    }

    function test_belowTheMinimumRevenueAccumulatesInsteadOfTrading() public {
        quote.mint(address(sink), 0.5 ether); // under the 1 ether floor

        sink.burn(Currency.wrap(address(quote)), 0.5 ether);

        assertEq(quote.balanceOf(address(sink)), 0.5 ether, "dust should accumulate");
        assertEq(sprout.balanceOf(TREASURY), 0, "nothing should have been bought");
    }

    /// D20: without a rate limit a searcher picks the moment of every buyback. With one, a
    /// second call in the same window parks instead of trading.
    function test_rateLimitParksASecondBuybackInTheSameWindow() public {
        vm.prank(TIMELOCK);
        sink.setGuards(1 ether, 500, 1 hours);

        quote.mint(address(sink), 100 ether);
        sink.burn(Currency.wrap(address(quote)), 100 ether);
        uint256 afterFirst = sprout.balanceOf(TREASURY);
        assertGt(afterFirst, 0, "the first buyback should have run");

        quote.mint(address(sink), 100 ether);
        sink.burn(Currency.wrap(address(quote)), 100 ether);
        assertEq(sprout.balanceOf(TREASURY), afterFirst, "the second buyback should have been rate-limited");
        assertEq(quote.balanceOf(address(sink)), 100 ether, "the parked tranche should still be here");

        vm.warp(block.timestamp + 1 hours);
        sink.buyback();
        assertGt(sprout.balanceOf(TREASURY), afterFirst, "the window reopened and it still did not run");
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
    function test_theConversionPoolIsDerivedRatherThanRegistered() public view {
        (PoolKey memory derived, bool zeroForOne) = sink.conversionPool(Currency.wrap(address(meme)));

        assertEq(
            PoolId.unwrap(derived.toId()), PoolId.unwrap(memePool.toId()), "the derived key is not the graduated pool"
        );
        assertEq(zeroForOne, address(meme) < address(quote), "the sell direction was derived wrongly");
    }

    /// D32. Convert is the default so the burn rate holds; a designated token accumulates
    /// instead. This is the old `PARK_NO_ROUTE` accident promoted to a policy that says so.
    function test_aLaunchTokenOnTheHoldAllowlistParksInsteadOfConverting() public {
        vm.prank(TIMELOCK);
        sink.setHold(Currency.wrap(address(meme)), true);

        uint256 supplyBefore = sprout.totalSupply();
        meme.mint(address(sink), 100 ether);

        vm.expectEmit(true, false, false, true, address(sink));
        emit BuybackBurnSink.Parked(Currency.wrap(address(meme)), 100 ether, 5);
        sink.burn(Currency.wrap(address(meme)), 100 ether);

        assertEq(meme.balanceOf(address(sink)), 100 ether, "a held token should accumulate");
        assertEq(sprout.totalSupply(), supplyBefore, "a held token must not reach the burn");

        // And it is a policy, not a one-way door: lifting the designation converts it.
        vm.prank(TIMELOCK);
        sink.setHold(Currency.wrap(address(meme)), false);
        sink.convert(Currency.wrap(address(meme)));
        assertLt(sprout.totalSupply(), supplyBefore, "lifting the hold did not release the conversion");
    }

    /// The impact bound is one price limit serving both legs, so an oversized conversion fills
    /// PARTIALLY against it and the rest stays here for the next window. It does NOT revert -
    /// `burn` cannot - and it does not hand the tranche to anybody either.
    function test_aConversionThatWouldBreachTheImpactBoundParksTheRemainder() public {
        vm.prank(TIMELOCK);
        sink.setGuards(1 ether, 50, INTERVAL); // 50 bps of sqrt price: very tight

        meme.mint(address(sink), 500_000 ether);
        sink.burn(Currency.wrap(address(meme)), 500_000 ether);

        uint256 leftover = meme.balanceOf(address(sink));
        assertGt(leftover, 0, "the bound did not bind - the whole tranche converted");
        assertLt(leftover, 500_000 ether, "the bound bound so hard that nothing converted");
        assertEq(meme.balanceOf(TREASURY), 0, "the remainder must stay here, not go to ops");
        assertGt(sprout.balanceOf(TREASURY), 0, "a partial conversion still has to reach the burn");
    }

    /// And the harder case the bound can produce: a pool already sitting past the limit refuses
    /// the swap outright. That is a revert inside the lock, so it has to park.
    function test_aConversionIntoAPausedPoolManagerParksInsteadOfBrickingTheHarvest() public {
        manager.pause();
        meme.mint(address(sink), 100 ether);

        vm.expectEmit(true, false, false, true, address(sink));
        emit BuybackBurnSink.Parked(Currency.wrap(address(meme)), 100 ether, 3);
        sink.burn(Currency.wrap(address(meme)), 100 ether);

        assertEq(meme.balanceOf(address(sink)), 100 ether, "the tranche should have parked here");
    }

    /// A caught failure must not spend the currency's window, and must not leave the transient
    /// lock flag set - the same two properties the buyback path has.
    function test_aFailedConversionSpendsNoWindowAndLeavesNoOpenLock() public {
        manager.pause();
        meme.mint(address(sink), 100 ether);
        sink.burn(Currency.wrap(address(meme)), 100 ether);
        assertEq(sink.lastConvertAt(Currency.wrap(address(meme))), 0, "a failed conversion moved the clock");

        vm.prank(address(vault));
        vm.expectRevert(BuybackBurnSink.LockNotOpen.selector);
        sink.lockAcquired(abi.encode(uint256(1)));

        manager.unpause();
        sink.convert(Currency.wrap(address(meme)));
        assertGt(sink.lastConvertAt(Currency.wrap(address(meme))), 0, "the retry was rate-limited by a failure");
        assertEq(meme.balanceOf(address(sink)), 0, "the parked tranche was not picked up");
    }

    /// D20 again: a conversion is a price-sensitive trade a permissionless caller times, so it
    /// is rate-limited. Per currency, or one launch token would gate every other one.
    function test_aConversionsWindowIsItsOwnCurrencysAlone() public {
        PoolKey memory meme2Pool = _graduationKey(meme2);
        _seed(meme2Pool, 100_000 ether);

        meme.mint(address(sink), 10 ether);
        sink.convert(Currency.wrap(address(meme)));
        assertEq(meme.balanceOf(address(sink)), 0, "the first conversion did not run");

        // Same currency, same window: parks.
        meme.mint(address(sink), 10 ether);
        vm.expectEmit(true, false, false, true, address(sink));
        emit BuybackBurnSink.Parked(Currency.wrap(address(meme)), 10 ether, 1);
        sink.convert(Currency.wrap(address(meme)));
        assertEq(meme.balanceOf(address(sink)), 10 ether, "a second conversion in the window traded");

        // A different currency is untouched by it.
        meme2.mint(address(sink), 10 ether);
        sink.convert(Currency.wrap(address(meme2)));
        assertEq(meme2.balanceOf(address(sink)), 0, "one launch token's window blocked another's");

        vm.warp(block.timestamp + INTERVAL);
        sink.convert(Currency.wrap(address(meme)));
        assertEq(meme.balanceOf(address(sink)), 0, "the window reopened and it still did not convert");
    }

    function test_belowItsOwnMinimumALaunchTokenAccumulates() public {
        vm.prank(TIMELOCK);
        sink.setMinConvertAmount(Currency.wrap(address(meme)), 5 ether);

        meme.mint(address(sink), 1 ether);
        vm.expectEmit(true, false, false, true, address(sink));
        emit BuybackBurnSink.Parked(Currency.wrap(address(meme)), 1 ether, 0);
        sink.burn(Currency.wrap(address(meme)), 1 ether);
        assertEq(meme.balanceOf(address(sink)), 1 ether, "dust should accumulate");

        meme.mint(address(sink), 4 ether);
        sink.burn(Currency.wrap(address(meme)), 4 ether);
        assertEq(meme.balanceOf(address(sink)), 0, "reaching the minimum did not release it");
    }

    function test_canConvertTracksTheGuards() public {
        Currency memeCurrency = Currency.wrap(address(meme));

        assertFalse(sink.canConvert(memeCurrency), "an empty sink should not claim it can convert");
        meme.mint(address(sink), 10 ether);
        assertTrue(sink.canConvert(memeCurrency), "funded and unrestricted, it should be able to convert");

        vm.prank(TIMELOCK);
        sink.setHold(memeCurrency, true);
        assertFalse(sink.canConvert(memeCurrency), "a held currency should report false");
        vm.prank(TIMELOCK);
        sink.setHold(memeCurrency, false);

        sink.convert(memeCurrency);
        meme.mint(address(sink), 10 ether);
        assertFalse(sink.canConvert(memeCurrency), "inside the interval it should report false");

        assertFalse(sink.canConvert(Currency.wrap(address(quote))), "the quote leg is not convertible");
        assertFalse(sink.canConvert(Currency.wrap(address(sprout))), "the burn token is not convertible");
        assertFalse(sink.canConvert(Currency.wrap(address(stray))), "a currency with no pool is not convertible");
    }

    /// `convert` is off the harvest path, so unlike `burn` it is allowed to say what is wrong.
    function test_convertRefusesEitherLegOfTheBuyback() public {
        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(quote)))
        );
        sink.convert(Currency.wrap(address(quote)));

        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(sprout)))
        );
        sink.convert(Currency.wrap(address(sprout)));
    }

    /// 🔴 The load-bearing check. A derived key is only trustworthy because a pool at it must
    /// have been opened by the settler, and that is true only while the tier carries the guard
    /// hook. A hookless tier is one anybody can open at a price of their choosing.
    function test_aHooklessConversionTierIsRefused() public {
        // Read outside the expectation: an argument that makes its own call would be the call
        // the cheatcode watches.
        bytes32 parameters = _graduationParameters();

        vm.prank(TIMELOCK);
        vm.expectRevert(BuybackBurnSink.ZeroAddress.selector);
        sink.setConversionTier(IPoolManager(address(manager)), IHooks(address(0)), FEE, parameters);
    }

    /// Neither leg of the buyback can be held, or `sweep`'s exclusion would be negotiable.
    function test_neitherBuybackLegCanBeHeld() public {
        vm.startPrank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(quote)))
        );
        sink.setHold(Currency.wrap(address(quote)), true);

        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.NotAConvertibleCurrency.selector, Currency.wrap(address(sprout)))
        );
        sink.setHold(Currency.wrap(address(sprout)), true);
        vm.stopPrank();
    }

    /// The contract's one invariant, restated over the leg A4 added: whatever the configuration
    /// and whatever the pool is doing, `burn` RETURNS. Fuzzed over the state rather than over the
    /// currency, because `ChoiceFeeController.harvest` can only ever hand this a currency it has
    /// just transferred - a token, always, never an arbitrary address.
    function testFuzz_burnNeverRevertsWhateverTheState(uint96 amount, bool held, bool paused, bool tierSet, uint8 leg)
        public
    {
        // A launch token with a pool, a second one, and a currency that has no pool anywhere.
        MockERC20 token = leg % 3 == 0 ? meme : (leg % 3 == 1 ? meme2 : stray);
        Currency currency = Currency.wrap(address(token));

        BuybackBurnSink target = _freshSink();
        vm.startPrank(TIMELOCK);
        target.setBuybackPool(pool);
        target.setGuards(1 ether, 500, INTERVAL);
        if (tierSet) {
            target.setConversionTier(
                IPoolManager(address(manager)), IHooks(address(guardHook)), FEE, _graduationParameters()
            );
        }
        if (held) target.setHold(currency, true);
        vm.stopPrank();

        token.mint(address(target), amount);
        if (paused) manager.pause();

        // No `expectRevert`, no `try`: the assertion is that this line returns at all.
        target.burn(currency, amount);

        if (paused) manager.unpause();
        // And nothing walked off with it - whatever happened, the funds are here or they are
        // wINJ/SPROUT that this contract went on to burn and split.
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
        sprout.mint(address(sink), 10 ether);
        vm.mockCallRevert(address(sprout), abi.encodeWithSelector(MockBurnableERC20.burn.selector), "burn is down");

        vm.expectEmit(true, false, false, true, address(sink));
        emit BuybackBurnSink.Parked(Currency.wrap(address(sprout)), 10 ether, 4);
        sink.burn(Currency.wrap(address(sprout)), 10 ether);

        assertEq(sprout.balanceOf(address(sink)), 10 ether, "the tranche should have parked here intact");
        assertEq(sprout.balanceOf(TREASURY), 0, "the treasury leg must not land on its own");
    }

    /// ⛔ THE reason the settle is one atomic self-call and not a `try` around each leg.
    ///
    /// With separate wrappers the burn lands, the transfer fails, and only the ops share is left
    /// sitting here - so the retry, which acts on the BALANCE like everything else in this
    /// contract, applies `burnBps` a second time and destroys 80% of the treasury's money. The
    /// split has to survive the failure whole, which means neither leg may land without the
    /// other.
    function test_aFailingTreasuryTransferLeavesTheWholeSplitForTheRetry() public {
        uint256 supplyBefore = sprout.totalSupply();
        sprout.mint(address(sink), 10 ether);
        vm.mockCallRevert(
            address(sprout), abi.encodeWithSelector(IERC20.transfer.selector, TREASURY), "treasury is blocked"
        );

        sink.burn(Currency.wrap(address(sprout)), 10 ether);

        assertEq(sprout.totalSupply(), supplyBefore + 10 ether, "the burn leg landed without the treasury leg");
        assertEq(sprout.balanceOf(address(sink)), 10 ether, "the tranche should have parked here intact");

        vm.clearMockedCalls();
        sink.burn(Currency.wrap(address(sprout)), 10 ether);

        uint256 burnt = supplyBefore + 10 ether - sprout.totalSupply();
        assertEq(burnt, 10 ether * uint256(FLOOR) / 10_000, "the retry did not burn burnBps of the WHOLE tranche");
        assertEq(sprout.balanceOf(TREASURY), 10 ether - burnt, "the treasury did not get the remainder");
        assertEq(sprout.balanceOf(address(sink)), 0, "the retry left something behind");
    }

    /// The buyback path is the worse of the two call sites: by the time the settle runs the swap
    /// has landed and `lastBuybackAt` is written, so a propagated revert would throw away a good
    /// buyback along with the harvest.
    function test_aFailingSettleDoesNotUnwindTheBuybackThatPrecededIt() public {
        quote.mint(address(sink), 100 ether);
        vm.mockCallRevert(address(sprout), abi.encodeWithSelector(MockBurnableERC20.burn.selector), "burn is down");

        sink.burn(Currency.wrap(address(quote)), 100 ether);

        assertGt(sink.lastBuybackAt(), 0, "the swap was unwound along with the settle");
        assertEq(quote.balanceOf(address(sink)), 0, "the quote was not spent, so the swap did not stand");
        assertGt(sprout.balanceOf(address(sink)), 0, "the bought SPROUT should be parked here");
        assertEq(sprout.balanceOf(TREASURY), 0, "nothing should have reached the treasury");

        // Nothing is stranded: the balance is what the next call acts on.
        vm.clearMockedCalls();
        uint256 parked = sprout.balanceOf(address(sink));
        sink.burn(Currency.wrap(address(sprout)), 0);
        assertEq(sprout.balanceOf(address(sink)), 0, "a later call did not pick the parked tranche up");
        assertEq(sprout.balanceOf(TREASURY), parked - parked * FLOOR / 10_000, "the retry shortchanged the treasury");
    }

    /// It moves the burn token, so it exists only to be `try`ed from inside this contract. An
    /// open one would be a permissionless way to force the split at a chosen moment.
    function test_settleBurnTokenSelfIsCallableOnlyByTheContractItself() public {
        sprout.mint(address(sink), 10 ether);

        vm.prank(STRANGER);
        vm.expectRevert(BuybackBurnSink.NotSelf.selector);
        sink.settleBurnTokenSelf();

        // Not an ownership gate either - the timelock has no more business calling it than
        // anyone else.
        vm.prank(TIMELOCK);
        vm.expectRevert(BuybackBurnSink.NotSelf.selector);
        sink.settleBurnTokenSelf();

        assertEq(sprout.balanceOf(address(sink)), 10 ether, "a refused call moved something anyway");
    }

    // ── guards that fail where they are set, not where they bite ───────────

    /// `_priceLimit` halves the setting, so 0 and 1 both produce a bound equal to the pool's
    /// own price - which no swap can cross. This was the value a sink carried before
    /// `setGuards` had ever been called.
    function test_anImpactGuardBelowItsFloorIsRefused() public {
        vm.startPrank(TIMELOCK);
        for (uint16 bps = 0; bps < 2; bps++) {
            vm.expectRevert(abi.encodeWithSelector(BuybackBurnSink.ImpactBpsTooLow.selector, bps, uint16(2)));
            sink.setGuards(1 ether, bps, INTERVAL);
        }
        sink.setGuards(1 ether, 2, INTERVAL); // the floor itself is fine
        vm.stopPrank();
        assertEq(sink.maxImpactBps(), 2);
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
        PoolKey memory ghost = _key(quote, sprout, 3000); // same legs, a tier nobody opened
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
            IBurnableERC20(address(sprout)),
            Currency.wrap(address(quote)),
            IVault(address(vault)),
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
        deal(address(sprout), address(sink), 10 ether);

        vm.startPrank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.CannotSweepBuybackLeg.selector, Currency.wrap(address(quote)))
        );
        sink.sweep(Currency.wrap(address(quote)), TIMELOCK);

        vm.expectRevert(
            abi.encodeWithSelector(BuybackBurnSink.CannotSweepBuybackLeg.selector, Currency.wrap(address(sprout)))
        );
        sink.sweep(Currency.wrap(address(sprout)), TIMELOCK);
        vm.stopPrank();

        assertEq(quote.balanceOf(address(sink)), 10 ether, "quote left the sink");
        assertEq(sprout.balanceOf(address(sink)), 10 ether, "burn token left the sink");
    }

    /// 🔴 A launch token became burn revenue the moment it became convertible, so excluding
    /// only wINJ and SPROUT stopped being enough. Sweeping now needs the D32 designation, which
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
        sink.setConversionTier(IPoolManager(address(manager)), IHooks(address(guardHook)), FEE, bytes32(0));
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
        bool quoteIsFirst = address(quote) < address(sprout);
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

    function _freshSink() internal returns (BuybackBurnSink) {
        return new BuybackBurnSink(
            IBurnableERC20(address(sprout)),
            Currency.wrap(address(quote)),
            IVault(address(vault)),
            TREASURY,
            TIMELOCK,
            FLOOR,
            FLOOR
        );
    }

    /// The `parameters` word a graduation pool carries: the hook's registration bitmap in the
    /// low bits, the tier's spacing above it - exactly `InfinitySettler.poolParameters()`.
    function _graduationParameters() internal view returns (bytes32) {
        return bytes32(uint256(guardHook.getHooksRegistrationBitmap())).setTickSpacing(SPACING);
    }

    /// The key `InfinitySettler` would graduate `token` onto, built the way the settler builds
    /// it: currencies sorted, the tier's fee and spacing, keyed to the guard hook.
    function _graduationKey(MockERC20 token) internal view returns (PoolKey memory) {
        (address c0, address c1) =
            address(token) < address(quote) ? (address(token), address(quote)) : (address(quote), address(token));
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(address(guardHook)),
            poolManager: IPoolManager(address(manager)),
            fee: FEE,
            parameters: _graduationParameters()
        });
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
