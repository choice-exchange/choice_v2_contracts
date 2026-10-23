// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {IStockVaultExtension} from "../src/interfaces/IStockVaultExtension.sol";
import {StockHedge} from "../src/stock/StockHedge.sol";
import {StockLib} from "../src/stock/StockLib.sol";
import {StockModule} from "../src/stock/StockModule.sol";
import {StockOps} from "../src/stock/StockOps.sol";
import {StockRegistry} from "../src/stock/StockRegistry.sol";
import {StockRestock} from "../src/stock/StockRestock.sol";
import {StockVault} from "../src/stock/StockVault.sol";
import {PriceStore} from "../src/stock/PriceStore.sol";
import {FixingConfig, Refusal, StockConfig, StockState} from "../src/stock/StockTypes.sol";
import {LazerBuilder} from "./utils/LazerBuilder.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// The exchange as the chain runs it (`MockStockExchange.chainLike`, on top of the mock's 18-decimal
/// balances, fees, relayer share, funding index and market status): the paths the 10-16 review found
/// the vault's model of the exchange wrong on. via-IR reads `block.number` once per function, so these
/// roll by explicit numbers.
contract StockChainFidelityTest is StockVaultHarness {
    string internal constant NEW_MARKET = "0x00000000000000000000000000000000000000000000000000000000000000bb";

    function setUp() public override {
        super.setUp();
        exchange.chainLike(1e15, 1e16);
        exchange.setBook(299.5e18, 300.5e18);
    }

    /// A market hedge crosses at most `minSpread`, so it has to cover the book's 17 bp half-spread.
    function _cfg() internal pure override returns (StockConfig memory c) {
        c = super._cfg();
        c.minSpread = 20;
    }

    function _hedgeAt(uint256 n, uint256 fillPrice) internal {
        vm.prank(KEEPER);
        assertTrue(x.syncHedge());
        vm.roll(n + 1);
        exchange.endBlock(fillPrice);
        x.confirmHedge();
    }

    function _deposit(uint256 amount) internal {
        cash.mint(DEPOSITOR, amount);
        vm.startPrank(DEPOSITOR);
        cash.approve(address(sv), amount);
        sv.deposit(amount, DEPOSITOR);
        vm.stopPrank();
    }

    /// Short 30, then the market's funding index goes negative, and the next fill stamps it on the
    /// position: from then on the exchange cannot read it back.
    function _unreadable(uint256 n) internal {
        _hedgeAt(n, 299.5e18);
        exchange.setCumulativeFunding(MARKET, -1e18);
        vm.roll(n + 2);
        _swap(false, true, 3 ether); // a trader sells the vault 3: the short is 3 short of what it holds
        vm.prank(KEEPER);
        assertTrue(x.syncHedge());
        vm.roll(n + 3);
        exchange.endBlock(299.5e18);
    }

    // ── a position the exchange cannot read ───────────────────────────────

    /// The funding settle a deposit runs would stamp the negative index on the position and leave it
    /// unreadable: it is undone, and the share is priced with funding unsettled.
    function test_aNegativeFundingIndexStillLetsSharesBePriced() public {
        uint256 n = block.number;
        _hedgeAt(n, 299.5e18);
        exchange.setCumulativeFunding(MARKET, -1e18);
        vm.roll(n + 2);
        cash.mint(DEPOSITOR, 100e6);
        vm.startPrank(DEPOSITOR);
        cash.approve(address(sv), 100e6);
        vm.expectEmit(address(sv));
        emit StockOps.FundingUnsettled();
        sv.deposit(100e6, DEPOSITOR);
        vm.stopPrank();
        exchange.subaccountPositions(_sub()); // still readable
        assertEq(x.state().shortConfirmed, 30 ether);
    }

    function test_anUnreadablePositionFreezesPricingButNotTheWayOut() public {
        uint256 n = block.number;
        _unreadable(n);
        vm.expectRevert(bytes("abi: negatively-signed value cannot be packed into uint parameter"));
        exchange.subaccountPositions(_sub());

        vm.expectRevert(StockLib.PositionUnreadable.selector);
        sv.totalAssets();
        vm.prank(KEEPER);
        vm.expectRevert(StockLib.PositionUnreadable.selector);
        x.syncHedge();
        _expectRefusal(Refusal.Unhedged);
        _swap(true, true, 100e6);
        x.confirmHedge(); // the cash leg still runs

        assertEq(sv.maxWithdraw(OWNER), 0, "the ERC-4626 views answer zero, not revert");
        assertEq(sv.maxDeposit(DEPOSITOR), 0);
        assertFalse(sv.navReady());

        vm.expectRevert(StockModule.NotKeeper.selector);
        x.coverUnreadable(40 ether, 301.8e18);
        vm.startPrank(KEEPER);
        vm.expectRevert(StockHedge.BadCover.selector);
        x.coverUnreadable(40 ether, 301.81e18); // past the mark's slippage
        vm.expectRevert(StockHedge.BadCover.selector);
        x.coverUnreadable(32.999 ether, 301.8e18); // under the most the short can be: 30 confirmed, 3 sold since
        x.coverUnreadable(40 ether, 301.8e18); // more than the short: the exchange cuts it to the short
        vm.stopPrank();
        vm.roll(n + 4);
        exchange.endBlock(300.5e18);

        exchange.subaccountPositions(_sub()); // no position: readable again
        x.confirmHedge();
        StockState memory s = x.state();
        assertEq(s.shortConfirmed, 0);
        assertFalse(s.positionLost, "its own cover closed it");
        assertEq(s.paused & 32, 32, "adding to the short is paused");
        sv.totalAssets();
        vm.prank(KEEPER);
        vm.expectRevert(StockHedge.PositionReadable.selector);
        x.coverUnreadable(1 ether, 300e18);

        // The vault holds 33 unhedged, but nobody re-opens the short (whose fill would stamp the index
        // again) until the owner lifts the pause.
        vm.roll(n + 5);
        vm.prank(KEEPER);
        assertFalse(x.syncHedge());
        vm.prank(OWNER);
        x.unpause(32);
        vm.prank(KEEPER);
        assertTrue(x.syncHedge());
    }

    /// A thin book fills the cover in pieces and the first piece stamps the index again: the second cover
    /// still asks for the most the short could be, so the confirmation after it sees its own buy.
    function test_aCoverFilledInPiecesIsNotALoss() public {
        uint256 n = block.number;
        _unreadable(n);
        exchange.setFillCap(20 ether);
        vm.prank(KEEPER);
        x.coverUnreadable(33 ether, 301.8e18);
        vm.roll(n + 4);
        exchange.endBlock(300.5e18); // 20 of 33: 13 left, stamped negative again
        vm.expectRevert(bytes("abi: negatively-signed value cannot be packed into uint parameter"));
        exchange.subaccountPositions(_sub());
        vm.prank(KEEPER);
        x.coverUnreadable(33 ether, 301.8e18);
        vm.roll(n + 5);
        exchange.endBlock(300.5e18);
        x.confirmHedge();
        assertFalse(x.state().positionLost);
        sv.totalAssets();
    }

    /// Once the market's index is back above zero, the funding settle a deposit runs re-stamps the
    /// position, and it reads again.
    function test_settlingFundingHealsTheReadOnceTheIndexIsBack() public {
        uint256 n = block.number;
        _unreadable(n);
        exchange.setCumulativeFunding(MARKET, 0.5e18);
        vm.roll(n + 4);
        _deposit(100e6);
        exchange.subaccountPositions(_sub());
        sv.totalAssets();
    }

    // ── a short gone with no cover of the vault's ─────────────────────────

    /// A paused market's positions are not listed: the short reads as gone though it is still there.
    /// No share is priced and no market migration runs until the owner has looked.
    function test_aShortGoneWithNoCoverIsLostUntilTheOwnerLooks() public {
        uint256 n = block.number;
        _hedgeAt(n, 299.5e18);
        exchange.setMarketActive(MARKET, false);
        vm.roll(n + 2);
        vm.expectEmit(address(sv));
        emit StockHedge.PositionLost(30 ether);
        x.confirmHedge();
        assertTrue(x.state().positionLost);
        assertEq(sv.maxDeposit(DEPOSITOR), 0);

        cash.mint(DEPOSITOR, 100e6);
        vm.startPrank(DEPOSITOR);
        cash.approve(address(sv), 100e6);
        vm.expectRevert(StockOps.NavNotReady.selector);
        sv.deposit(100e6, DEPOSITOR);
        vm.stopPrank();
        vm.startPrank(OWNER);
        x.haltAction();
        vm.expectRevert(StockHedge.HedgeOpen.selector);
        x.migrateMarket(NEW_MARKET, 1e15, 1e16);
        x.acceptNav();
        vm.stopPrank();
        assertFalse(x.state().positionLost);
    }

    /// Before anyone confirms it, a short gone missing already stops shares being priced: nobody can
    /// deposit, or settle the queue, at the value without it.
    function test_aMissingShortStopsPricingEvenBeforeItIsConfirmed() public {
        uint256 n = block.number;
        _hedgeAt(n, 299.5e18);
        exchange.setMarketActive(MARKET, false);
        vm.roll(n + 2);
        assertEq(sv.maxDeposit(DEPOSITOR), 0);
        assertFalse(sv.navReady());
        cash.mint(DEPOSITOR, 100e6);
        vm.startPrank(DEPOSITOR);
        cash.approve(address(sv), 100e6);
        vm.expectRevert(StockOps.NavNotReady.selector);
        sv.deposit(100e6, DEPOSITOR);
        vm.stopPrank();
    }

    // ── the market id ─────────────────────────────────────────────────────

    /// Orders take any spelling, but positions come back lowercase: an id in any other spelling would
    /// never find the short it opened.
    function test_aMarketIdIsTheExchangesOwnSpelling() public {
        vm.startPrank(OWNER);
        x.haltAction();
        vm.expectRevert(StockLib.BadMarket.selector);
        x.migrateMarket("0x00000000000000000000000000000000000000000000000000000000000000BB", 1e15, 1e16);
        vm.expectRevert(StockLib.BadMarket.selector);
        x.migrateMarket("00000000000000000000000000000000000000000000000000000000000000bb", 1e15, 1e16);
        x.migrateMarket(NEW_MARKET, 1e15, 1e16);
        vm.stopPrank();

        StockVault.Init memory init = StockVault.Init({
            cash: IERC20(address(cash)),
            stock: IERC20(address(stock)),
            poolManager: ICLPoolManager(address(manager)),
            store: store,
            calendar: calendar,
            modules: sv.MODULES(),
            registry: address(registry),
            ratios: ratios,
            feedId: FEED,
            cashFeedId: 0,
            marketId: "0x00000000000000000000000000000000000000000000000000000000000000AA",
            cashDenom: CASH_DENOM,
            owner: OWNER,
            name: "Stock vault",
            symbol: "SV"
        });
        vm.expectRevert(StockLib.BadMarket.selector);
        new StockVault(init, _cfg());
    }

    // ── fees, fractions and the book ──────────────────────────────────────

    /// A sell filled above its worst price, a cover's fractional payout, and the relayer share of the
    /// vault's own fees: every whole unit the exchange holds for the vault comes back but the one it never
    /// asks for, and the relayer share arrives in the bank as cash to book.
    function test_aHedgeRoundTripUnderChainRulesBringsTheCashBack() public {
        uint256 n = block.number;
        bytes32 sub = keccak256(bytes(_sub()));
        _hedgeAt(n, 299.5e18);
        assertLe(exchange.depositTotal(sub), 1, "all but one unit came back");
        // 40% of the fee, 299.5 * 30 * 0.0001%: 3,594 units to the vault's default subaccount, then its bank.
        vm.expectEmit(address(sv));
        emit StockRestock.CashWindfall(3594);
        x.syncWindfall();

        vm.roll(n + 2);
        _swap(true, false, 10 ether); // a taker buys 10: the short is 10 over
        vm.prank(KEEPER);
        assertTrue(x.syncHedge()); // a reduce-only cover, its worst price above the ask
        vm.roll(n + 3);
        exchange.endBlock(300.53e18); // its fee, 3,005.3 units, is no whole number
        (int256 available,) = exchange.depositExact(_sub());
        assertGt(available % int256(exchange.cashScale()), 0, "the payout left a fraction");
        x.confirmHedge();
        assertLe(exchange.depositTotal(sub), 1, "all but one unit came back again");
        _deposit(100e6); // with the short open: its funding settle passes the reduce-margin check
    }

    /// The exchange refuses a market order that does not cross the book at placement. Anyone's hedge may
    /// cross only the vault's narrowest spread, so inside a wider book it cannot go out: the keeper's can.
    /// A market hedge crosses at most `minSpread`, the keeper's as much as anyone's: in a book wider than
    /// that nobody's goes through, until the spread the vault charges covers crossing it.
    function test_aHedgeInsideABookWiderThanTheSpreadIsRefused() public {
        uint256 n = block.number;
        _hedgeAt(n, 299.5e18);
        vm.warp(block.timestamp + 301);
        _price(MANTISSA);
        vm.roll(n + 2);
        _swap(false, true, 3 ether);
        exchange.setBook(299.3e18, 300.7e18); // 23 bp a side
        vm.expectRevert(bytes("slippage exceeds worst price"));
        x.syncHedge();
        vm.prank(KEEPER);
        vm.expectRevert(bytes("slippage exceeds worst price"));
        x.syncHedge();
        StockConfig memory c = _cfg();
        c.minSpread = 25;
        _setCfg(c);
        vm.prank(KEEPER);
        assertTrue(x.syncHedge());
    }

    /// The exchange checks its minimum notional at the order's own price, which may be the slippage under
    /// the reference: the vault judges its minimum there too.
    function test_theMinimumHedgeIsJudgedAtTheWorstPrice() public {
        uint256 n = block.number;
        _hedgeAt(n, 299.5e18);
        vm.roll(n + 2);
        _minHedge(1_199_000); // 0.004 a share is 1.20 at the reference, 1.1976 at the worst
        _swap(false, true, 0.004 ether);
        vm.prank(KEEPER);
        assertFalse(x.syncHedge(), "under the minimum at the worst price");
        _minHedge(1_190_000);
        vm.roll(n + 3);
        vm.prank(KEEPER);
        assertTrue(x.syncHedge());
    }

    function _minHedge(uint96 minHedge) internal {
        StockConfig memory c = _cfg();
        c.hedgeBand = 1e6;
        c.minHedge = minHedge;
        _setCfg(c);
    }

    // ── a full exit ───────────────────────────────────────────────────────

    /// Mainnet 10-20: once the short was covered to zero, `requestRedeem(every share)` and then
    /// `settleRedeems` reverted `CashShortForQueue(28942837, 28942836)`. The subaccount keeps the unit the
    /// vault never withdraws (`StockLib.subaccountCash`), and the value counted it, so every share's claim
    /// was a unit more than any cash exit could pay. The value counts only what can come back now: the
    /// whole vault leaves in cash, to the unit, and nothing is left behind.
    function test_aFullExitSettlesInCashOnceTheShortIsCovered() public {
        _freshVault(10_000e6);
        StockConfig memory c = _cfg();
        c.exitFeeBps = 0; // what the leaver gets is then the shares' value itself
        c.targetInventory = 3_000e6; // the short runs 10 ahead of a restock
        _setCfg(c);
        uint256 n = block.number;
        _hedgeAt(n, 299.5e18);
        assertEq(x.state().shortConfirmed, 10 ether);
        c.targetInventory = 0; // the restock never comes: the short follows the holding, none
        _setCfg(c);
        vm.roll(n + 2);
        _hedgeAt(n + 2, 300.53e18); // covered at a loss, with a fee: the payout is no whole number
        assertEq(x.state().shortConfirmed, 0);
        (, uint256 kept) = exchange.subaccountDeposit(_sub(), CASH_DENOM);
        assertEq(kept, 1, "the subaccount keeps the unit the vault never withdraws");
        x.syncWindfall(); // the relayer share of the vault's own fees, booked

        uint256 nav = sv.totalAssets();
        uint256 booked = x.state().cashBooked;
        uint256 shares = sv.balanceOf(DEPOSITOR);
        uint256 value = sv.previewRedeem(shares);
        uint256 instant = sv.maxWithdraw(DEPOSITOR);
        vm.prank(DEPOSITOR);
        x.requestRedeem(shares, DEPOSITOR, DEPOSITOR);
        x.settleRedeems(); // reverted CashShortForQueue(booked + 1, booked)
        vm.prank(DEPOSITOR);
        (uint256 paid,) = x.claimRedeem(DEPOSITOR, DEPOSITOR);

        assertEq(nav, booked, "the value is the cash the vault holds, not the unit it leaves");
        assertEq(instant, value, "an instant exit could have taken all of it too");
        assertEq(paid, value, "the leaver gets the shares' value");
        assertEq(paid, nav, "which is the whole vault, to the unit");
        assertEq(sv.totalSupply(), 0);
        assertEq(sv.totalAssets(), 0, "nothing is left behind");
        assertEq(cash.balanceOf(address(sv)) + _claims(cash), 0, "not a unit of cash");
    }

    /// A second vault on the same pool manager, its shares still at their first price as the rehearsal
    /// vault's were: cash deposited, no stock. (The harness books 30 STOCK as a windfall, which nearly
    /// doubles the share price, and the ERC-4626 virtual shares then own about two units of the value:
    /// enough to hide the unit no exit could pay.) The suite's helpers act on it from here on.
    function _freshVault(uint256 amount) internal {
        StockRegistry reg = new StockRegistry(OWNER); // one vault per stock in a registry
        sv = new StockVault(
            StockVault.Init({
                cash: IERC20(address(cash)),
                stock: IERC20(address(stock)),
                poolManager: ICLPoolManager(address(manager)),
                store: store,
                calendar: calendar,
                modules: sv.MODULES(),
                registry: address(reg),
                ratios: ratios,
                feedId: FEED,
                cashFeedId: 0,
                marketId: MARKET,
                cashDenom: CASH_DENOM,
                owner: OWNER,
                name: "Stock vault",
                symbol: "SV"
            }),
            _cfg()
        );
        x = IStockVaultExtension(address(sv));
        key.hooks = IHooks(address(sv));
        vm.startPrank(OWNER);
        reg.setIssuerCap(ISSUER, 1_000_000e6);
        reg.register(address(sv), address(stock), ISSUER, _cfg().maxInventory);
        x.setRoles(KEEPER, GUARDIAN, ISSUER);
        x.setDepositor(DEPOSITOR, true);
        manager.initialize(key, _sqrtAt(300));
        vm.stopPrank();
        _deposit(amount);
    }
}

/// A vault whose cash has its own feed: the stock's USD price divided by the cash's.
contract StockCashFeedTest is StockVaultHarness {
    uint32 internal constant CASH_FEED = 8;

    function _cashFeed() internal pure override returns (uint32) {
        return CASH_FEED;
    }

    function _newStore() internal override returns (PriceStore s) {
        s = super._newStore();
        uint64 ts = uint64(block.timestamp) * 1e6;
        s.update(LazerBuilder.one(SIGNER_KEY, ts, LazerBuilder.Feed(CASH_FEED, 99_000_000, -8, 0, ts, 0, 0, -1)));
    }

    /// 300 USD at 0.99 USD a cash unit is 303.03 in cash; the keeper's sell may go 10 bps under that.
    function test_theStockIsPricedInTheCashNotInUsd() public {
        vm.prank(KEEPER);
        assertTrue(x.syncHedge());
        assertEq(exchange.pending(0).worstPrice, 302.72e18);
    }

    /// The fixing lane prices its tick in the cash too, with the cash's price from the same update, so the
    /// settler picks no moment for it: an update without the cash's feed cannot settle.
    function test_aFixingPricesTheTickInTheCashFromTheSameUpdate() public {
        uint64 boundary = uint64(TUE + 16 hours);
        uint64 tickUs = (boundary * 1000 + 5000) * 1000;
        vm.prank(OWNER);
        x.setFixingConfig(
            FixingConfig({
                interval: 3600,
                delayMs: 5000,
                settleWindow: 30,
                spreadBps: 10,
                sizeBps: 0,
                maxSpreadBps: 100,
                minRequest: 10e6,
                maxSide: 100_000e6,
                maxNet: 50_000e6
            })
        );
        cash.mint(TRADER, 3_000e6);
        vm.startPrank(TRADER);
        cash.approve(address(sv), 3_000e6);
        x.commitFixing(boundary, true, 3_000e6, TRADER);
        vm.stopPrank();
        vm.warp(boundary + 6);

        LazerBuilder.Feed[] memory feeds = new LazerBuilder.Feed[](1);
        feeds[0] = LazerBuilder.Feed(FEED, MANTISSA, -5, 0, tickUs, 0, 0, -1);
        vm.expectRevert(abi.encodeWithSelector(PriceStore.FeedNotFound.selector, CASH_FEED));
        x.settleFixing(boundary, LazerBuilder.sign(SIGNER_KEY, LazerBuilder.payload(tickUs, feeds)));

        feeds = new LazerBuilder.Feed[](2);
        feeds[0] = LazerBuilder.Feed(FEED, MANTISSA, -5, 0, tickUs, 0, 0, -1);
        feeds[1] = LazerBuilder.Feed(CASH_FEED, 99_000_000, -8, 0, tickUs, 0, 0, -1);
        x.settleFixing(boundary, LazerBuilder.sign(SIGNER_KEY, LazerBuilder.payload(tickUs, feeds)));
        assertEq(x.fixingBatch(boundary).price, Math.mulDiv(PRICE, 1e18, 0.99e18));
    }

    function test_aStaleCashPriceRefusesLikeAStaleStockPrice() public {
        vm.warp(block.timestamp + 61);
        _price(MANTISSA); // the stock's price is fresh, the cash's is not
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Stale));
        x.syncHedge();
    }
}
