// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
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

import {BuybackBurnSink} from "../src/fees/BuybackBurnSink.sol";
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
    MockERC20 internal stray; // a launch token with no route

    BuybackBurnSink internal sink;
    PoolKey internal pool;

    function setUp() public {
        vault = new Vault();
        manager = new CLPoolManager(vault);
        vault.registerApp(address(manager));
        seeder = new CLPoolManagerRouter(vault, manager);

        quote = new MockERC20("Wrapped INJ", "wINJ", 18);
        sprout = new MockBurnableERC20("Sprout", "SPROUT", 18);
        stray = new MockERC20("Launch", "LAUNCH", 18);

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

        vm.startPrank(TIMELOCK);
        sink.setBuybackPool(pool);
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

    /// `burn` is what `ChoiceFeeController.harvest` calls after transferring. If it can revert,
    /// a launch token with no pool bricks harvesting for that currency - so it must not.
    function test_burnDoesNotRevertOnACurrencyWithNoRoute() public {
        stray.mint(address(sink), 5 ether);

        sink.burn(Currency.wrap(address(stray)), 5 ether);

        assertEq(stray.balanceOf(address(sink)), 5 ether, "unroutable funds should be held, not moved");
        assertEq(stray.balanceOf(TREASURY), 0, "ops must not receive what the burn was entitled to");
    }

    /// An unconfigured sink must also park rather than revert, or wiring it in the wrong order
    /// would brick harvests until someone noticed.
    function test_burnDoesNotRevertBeforeAPoolIsConfigured() public {
        BuybackBurnSink fresh = new BuybackBurnSink(
            IBurnableERC20(address(sprout)),
            Currency.wrap(address(quote)),
            IVault(address(vault)),
            TREASURY,
            TIMELOCK,
            FLOOR,
            FLOOR
        );
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

    function test_sweepRecoversAStrandedThirdCurrency() public {
        stray.mint(address(sink), 7 ether);

        vm.prank(TIMELOCK);
        sink.sweep(Currency.wrap(address(stray)), TREASURY);

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
