// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {StockHedge} from "../src/stock/StockHedge.sol";
import {StockLib} from "../src/stock/StockLib.sol";
import {StockModule} from "../src/stock/StockModule.sol";
import {StockOps} from "../src/stock/StockOps.sol";
import {StockRestock} from "../src/stock/StockRestock.sol";
import {StockVault} from "../src/stock/StockVault.sol";
import {PriceStore} from "../src/stock/PriceStore.sol";
import {Refusal, StockConfig, StockState} from "../src/stock/StockTypes.sol";
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

        vm.expectRevert(StockModule.NotKeeper.selector);
        x.coverUnreadable(40 ether, 301.8e18);
        vm.startPrank(KEEPER);
        vm.expectRevert(StockHedge.BadCover.selector);
        x.coverUnreadable(40 ether, 301.81e18); // past the mark's slippage
        x.coverUnreadable(40 ether, 301.8e18); // more than the short: the exchange cuts it to the short
        vm.stopPrank();
        vm.roll(n + 4);
        exchange.endBlock(300.5e18);

        exchange.subaccountPositions(_sub()); // no position: readable again
        x.confirmHedge();
        StockState memory s = x.state();
        assertEq(s.shortConfirmed, 0);
        assertFalse(s.positionLost, "its own cover closed it");
        sv.totalAssets();
        vm.prank(KEEPER);
        vm.expectRevert(StockHedge.PositionReadable.selector);
        x.coverUnreadable(1 ether, 300e18);
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
    function test_aStrangersHedgeInsideAWideBookIsRefused() public {
        uint256 n = block.number;
        _hedgeAt(n, 299.5e18);
        vm.warp(block.timestamp + 301);
        _price(MANTISSA);
        vm.roll(n + 2);
        _swap(false, true, 3 ether);
        vm.expectRevert(bytes("slippage exceeds worst price"));
        x.syncHedge();
        vm.prank(KEEPER);
        assertTrue(x.syncHedge());
    }

    /// The exchange checks its minimum notional at the order's own price, which may be the slippage under
    /// the reference: the vault judges its minimum there too.
    function test_theMinimumHedgeIsJudgedAtTheWorstPrice() public {
        uint256 n = block.number;
        _hedgeAt(n, 299.5e18);
        vm.roll(n + 2);
        _minHedge(1_195_000); // 0.004 a share is 1.20 at the reference, 1.1928 at the worst
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

    /// 300 USD at 0.99 USD a cash unit is 303.03 in cash; the keeper's sell may go 60 bps under that.
    function test_theStockIsPricedInTheCashNotInUsd() public {
        vm.prank(KEEPER);
        assertTrue(x.syncHedge());
        assertEq(exchange.pending(0).worstPrice, 301.21e18);
    }

    function test_aStaleCashPriceRefusesLikeAStaleStockPrice() public {
        vm.warp(block.timestamp + 61);
        _price(MANTISSA); // the stock's price is fresh, the cash's is not
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Stale));
        x.syncHedge();
    }
}
