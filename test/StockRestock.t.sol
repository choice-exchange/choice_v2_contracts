// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StockLib} from "../src/stock/StockLib.sol";
import {StockModule} from "../src/stock/StockModule.sol";
import {StockRestock} from "../src/stock/StockRestock.sol";
import {Refusal, StockConfig, StockState} from "../src/stock/StockTypes.sol";
import {LazerBuilder} from "./utils/LazerBuilder.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// LIMIT memo restocking, both directions: the memo the vault builds, the limit bands, what an order
/// is worth in transit, and every way one closes (delivered, paid, refunded, lapsed), by anyone, off
/// what the two ledgers see arrive.
contract StockRestockTest is StockVaultHarness {
    // Any issuer format, placeholders where the numbers go; the vault writes the payee (0x04) and the
    // expiry key and value (0x03) itself.
    bytes internal constant TEMPLATE = '{"did_id":"\x04","give":"\x01","want":"\x02",\x03}';

    function setUp() public override {
        super.setUp();
        vm.prank(OWNER);
        x.setRestockMemo(TEMPLATE);
    }

    function _memo(uint256 offer, uint256 request, uint256 expiry) internal view returns (bytes memory) {
        return abi.encodePacked(
            '{"did_id":"',
            vm.toLowercase(vm.toString(address(sv))),
            '","give":"',
            vm.toString(offer),
            '","want":"',
            vm.toString(request),
            '","expiry_days":',
            vm.toString(expiry),
            "}"
        );
    }

    function _order(bool sell, uint256 amountIn, uint256 limitOut) internal {
        vm.prank(KEEPER);
        x.restock(sell, amountIn, limitOut, 1);
    }

    function _value(uint256 stockAmount) internal pure returns (uint256) {
        return stockAmount * PRICE / 1e30;
    }

    // ── the order ─────────────────────────────────────────────────────────

    function test_theMemoCarriesTheOrdersOwnNumbers() public {
        bytes memory memo = _memo(3_000e6, 9.8 ether, 2);
        vm.expectCall(address(cash), abi.encodePacked(abi.encodeCall(IERC20.transfer, (ISSUER, 3_000e6)), memo));
        vm.expectEmit(address(sv));
        emit StockRestock.RestockOrdered(false, 3_000e6, 9.8 ether, uint64(block.timestamp + 2 days + 3600), memo);
        vm.prank(KEEPER);
        x.restock(false, 3_000e6, 9.8 ether, 2);
        assertEq(cash.balanceOf(ISSUER), 3_000e6);
    }

    function test_aSellSendsTheStockWithTheMemo() public {
        bytes memory memo = _memo(10 ether, 2_950e6, 1);
        vm.expectCall(address(stock), abi.encodePacked(abi.encodeCall(IERC20.transfer, (ISSUER, 10 ether)), memo));
        _order(true, 10 ether, 2_950e6);
        assertEq(stock.balanceOf(ISSUER), 10 ether);
        StockState memory s = x.state();
        assertTrue(s.orderOpen && s.orderSell);
        assertEq(s.stockBooked, 20 ether);
        assertEq(s.orderStock, 10 ether);
        assertEq(s.orderCash, 2_950e6);
    }

    function test_theTemplateNeedsEachPlaceholderOnce() public {
        vm.startPrank(OWNER);
        vm.expectRevert(StockRestock.BadMemo.selector);
        x.setRestockMemo(hex"7b0102"); // no expiry
        vm.expectRevert(StockRestock.BadMemo.selector);
        x.setRestockMemo(hex"0102030201"); // twice
        vm.expectRevert(StockRestock.BadMemo.selector);
        x.setRestockMemo(new bytes(1025));
        x.setRestockMemo("");
        vm.stopPrank();
        vm.prank(KEEPER);
        vm.expectRevert(StockRestock.RestockUnavailable.selector);
        x.restock(false, 1_000e6, 3.3 ether, 1);
    }

    function test_onlyTheOwnerSetsTheTemplate() public {
        vm.prank(KEEPER);
        vm.expectRevert(StockModule.NotOwner.selector);
        x.setRestockMemo(TEMPLATE);
    }

    function test_onlyTheKeeperRestocks() public {
        vm.expectRevert(StockModule.NotKeeper.selector);
        x.restock(false, 1_000e6, 3.3 ether, 1);
    }

    // ── limits ────────────────────────────────────────────────────────────

    function test_aBuysLimitMustBeNearTheReference() public {
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockRestock.LimitOutOfBand.selector, 2_700e6, 2_910e6));
        x.restock(false, 3_000e6, 9 ether, 1);
    }

    function test_aSalesLimitMustBeNearTheReference() public {
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockRestock.LimitOutOfBand.selector, 2_900e6, 2_910e6));
        x.restock(true, 10 ether, 2_900e6, 1);
        _order(true, 10 ether, 2_910e6);
    }

    function test_aSaleSellsOnlyBookedStock() public {
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockRestock.NotEnoughStock.selector, 31 ether, 30 ether));
        x.restock(true, 31 ether, 9_000e6, 1);
    }

    function test_bothSidesCountAgainstTheDailyCap() public {
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.RestockCapExceeded.selector, 10_001e6, 10_000e6));
        x.restock(false, 10_001e6, 34 ether, 1);

        _order(true, 25 ether, 7_400e6); // 7,500 of stock
        cash.mint(address(sv), 7_400e6);
        x.settleRestock(); // paid
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.RestockCapExceeded.selector, 3_000e6, 2_500e6));
        x.restock(false, 3_000e6, 9.8 ether, 1);
    }

    function test_aSaleRefundedInStockGivesItsCapBack() public {
        _order(true, 25 ether, 7_400e6);
        assertEq(x.state().restockUsed, 7_500e6);
        stock.mint(address(sv), 25 ether); // the issuer sends the stock back
        x.settleRestock();
        assertEq(x.state().restockUsed, 0, "seen to come back, so it no longer counts");
        _order(false, 6_000e6, 19.9 ether);
    }

    function test_aBuyRefundedInCashGivesItsCapBack() public {
        _order(false, 3_000e6, 9.8 ether);
        assertEq(x.state().restockUsed, 3_000e6);
        cash.mint(address(sv), 3_000e6); // the issuer refunds
        x.settleRestock();
        assertEq(x.state().restockUsed, 0, "seen to come back on the cash ledger, so it no longer counts");
        assertEq(cash.balanceOf(address(sv)), 0, "the refund went into claims");
    }

    /// A sale's payment is settled into claims, so the cash it raised pays the next sell at once.
    function test_aSalesPaymentIsSettledIntoClaims() public {
        uint256 held = cash.balanceOf(address(sv)) + _claims(cash);
        _order(true, 10 ether, 2_950e6);
        cash.mint(address(sv), 2_960e6); // the issuer pays, above the limit
        x.settleRestock();
        assertEq(x.state().cashBooked, held + 2_960e6);
        assertEq(cash.balanceOf(address(sv)), 0, "nothing left plain");
        assertEq(_claims(cash), held + 2_960e6, "all of it in claims");
    }

    function test_aRefundAfterItsWindowGivesNothingBack() public {
        _order(true, 25 ether, 7_400e6);
        vm.warp(block.timestamp + 1 days);
        _price(MANTISSA);
        stock.mint(address(sv), 25 ether);
        x.settleRestock();
        assertEq(x.state().restockUsed, 7_500e6, "a stale window is left as it was");
        _order(false, 6_000e6, 19.9 ether); // the new window starts from zero
        assertEq(x.state().restockUsed, 6_000e6);
    }

    function test_oneOrderAtATime() public {
        _order(false, 1_000e6, 3.3 ether);
        vm.prank(KEEPER);
        vm.expectRevert(StockRestock.RestockUnavailable.selector);
        x.restock(true, 1 ether, 290e6, 1);
    }

    function test_aBuyStaysUnderTheInventoryCap() public {
        StockConfig memory c = _cfg();
        c.maxInventory = 10_000e6; // 9,000 held
        _setCfg(c);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockRestock.InventoryCapExceeded.selector, 10_020e6, 10_000e6));
        x.restock(false, 1_020e6, 3.4 ether, 1);
    }

    function test_anOrderMayNotOutliveTheLongestLife() public {
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockRestock.OrderTooLong.selector, 8 days));
        x.restock(false, 1_000e6, 3.3 ether, 8);
    }

    function test_noRestockOnAJumpFromTheAnchor() public {
        x.poke(); // anchored at 300
        _price(40_000_000); // 400, a 33% jump
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Jump));
        x.restock(false, 1_000e6, 2.5 ether, 1);
    }

    function test_noRestockWhileTheMarketIsClosed() public {
        vm.warp(SAT + 12 hours);
        LazerBuilder.Feed memory f = _feed(MANTISSA);
        f.feedTimestampUs = uint64(SAT) * 1e6 - 200_000;
        store.update(_update(f));
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Closed));
        x.restock(false, 1_000e6, 3.3 ether, 1);
    }

    // ── in transit and closing ────────────────────────────────────────────

    function test_aBuyIsCountedOnceThroughDelivery() public {
        uint256 nav = sv.totalAssets();
        _order(false, 3_000e6, 9.8 ether);
        // In transit as the stock it buys, at the mark (it is hedged as that): 2,940 for 3,000 sent.
        assertEq(sv.totalAssets(), nav - 60e6, "in transit at its stock");
        stock.mint(address(sv), 10 ether); // filled better than the limit
        assertEq(sv.totalAssets(), nav - 60e6, "a delivery is not counted twice before it is booked");
        x.settleRestock();
        StockState memory s = x.state();
        assertFalse(s.orderOpen);
        assertEq(s.stockBooked, 40 ether);
        assertEq(_claims(stock), 40 ether, "the delivery goes straight to claims");
        assertEq(sv.totalAssets(), nav);
    }

    function test_aShortDeliveryWaitsAndThenBooksAsAWindfall() public {
        uint256 nav = sv.totalAssets();
        _order(false, 3_000e6, 9.8 ether);
        stock.mint(address(sv), 5 ether); // under the limit
        vm.expectRevert(abi.encodeWithSelector(StockRestock.NotDelivered.selector, 5 ether, 9.8 ether));
        x.settleRestock();
        vm.warp(block.timestamp + 1 days + 3601);
        vm.prank(OWNER);
        x.writeOffRestock(); // past the deadline: written off, and what came is booked
        assertEq(x.state().stockBooked, 35 ether);
        _price(MANTISSA);
        assertEq(sv.totalAssets(), nav - 3_000e6 + 1_500e6, "the cash left, the stock that came is booked");
        _order(false, 1_000e6, 3.3 ether); // and restocking goes on
    }

    function test_aRefundedBuyIsCountedOnceAndClosesForAnyone() public {
        uint256 nav = sv.totalAssets();
        _order(false, 3_000e6, 9.8 ether);
        cash.mint(address(sv), 3_000e6); // the issuer refunds
        assertEq(sv.totalAssets(), nav - 60e6, "an unbooked refund is not counted twice");
        vm.expectEmit(address(sv));
        emit StockRestock.RestockRefunded(false, 3_000e6);
        x.settleRestock();
        assertEq(sv.totalAssets(), nav);
        assertEq(x.state().cashBooked, 10_000e6);
        _order(false, 1_000e6, 3.3 ether);
    }

    function test_anOrderWithNothingBackIsWrittenOffAndItsLateLegIsAWindfall() public {
        uint256 nav = sv.totalAssets();
        _order(false, 3_000e6, 9.8 ether);
        vm.warp(block.timestamp + 1 days + 3600);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockRestock.NotDelivered.selector, 0, 9.8 ether));
        x.writeOffRestock(); // not before the deadline
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(StockRestock.NotDelivered.selector, 0, 9.8 ether));
        x.settleRestock(); // nor by anyone: the deadline alone closes nothing
        assertEq(sv.totalAssets(), nav - 60e6, "still open, still in the value");
        vm.expectRevert(StockModule.NotOwner.selector);
        x.writeOffRestock();
        vm.prank(OWNER);
        vm.expectEmit(address(sv));
        emit StockRestock.RestockLapsed(false, 3_000e6);
        x.writeOffRestock();
        assertEq(sv.totalAssets(), nav - 3_000e6, "written off: out of the value");
        cash.mint(address(sv), 3_000e6); // refunded late
        assertEq(sv.totalAssets(), nav - 3_000e6, "not counted until booked");
        x.syncWindfall();
        assertEq(sv.totalAssets(), nav);
    }

    function test_aGiftShortOfTheLegCannotCloseAnOrder() public {
        uint256 nav = sv.totalAssets();
        _order(true, 10 ether, 2_950e6);
        cash.mint(address(sv), 2_949e6);
        vm.expectRevert(abi.encodeWithSelector(StockRestock.NotDelivered.selector, 0, 10 ether));
        x.settleRestock();
        assertEq(sv.totalAssets(), nav, "and is out of the value meanwhile");
    }

    function test_cashHereBeforeAnOrderIsBookedFirstAndCannotSettleIt() public {
        uint256 nav = sv.totalAssets();
        cash.mint(address(sv), 500e6); // a donation, or a late leg of an earlier order
        assertEq(sv.totalAssets(), nav);
        vm.expectEmit(address(sv));
        emit StockRestock.CashWindfall(500e6);
        _order(false, 400e6, 1.3 ether);
        vm.expectRevert(abi.encodeWithSelector(StockRestock.NotDelivered.selector, 0, 1.3 ether));
        x.settleRestock();
    }

    function test_aSaleInTransitStaysInTheValueAndTheHedge() public {
        uint256 nav = sv.totalAssets();
        int256 gap = sv.hedgeGap();
        _order(true, 10 ether, 2_950e6);
        assertEq(sv.totalAssets(), nav, "the stock in transit is valued at the mark");
        assertEq(sv.hedgeGap(), gap, "and stays hedged until paid");
    }

    function test_aPaidSaleClosesAndLeavesTheCash() public {
        uint256 nav = sv.totalAssets();
        _order(true, 10 ether, 2_950e6);
        cash.mint(address(sv), 2_950e6); // the issuer pays at the limit
        assertEq(sv.totalAssets(), nav, "still the stock in transit; the payment waits to be booked");
        vm.expectEmit(address(sv));
        emit StockRestock.Restocked(true, 10 ether, 2_950e6);
        x.settleRestock();
        assertEq(sv.totalAssets(), nav - 3_000e6 + 2_950e6);
        assertEq(x.state().stockBooked, 20 ether);
    }

    function test_aRefundedSaleIsBookedBackByAnyone() public {
        uint256 nav = sv.totalAssets();
        _order(true, 10 ether, 2_950e6);
        stock.mint(address(sv), 10 ether); // the issuer sends the stock back
        vm.expectEmit(address(sv));
        emit StockRestock.RestockRefunded(true, 10 ether);
        x.settleRestock();
        assertEq(x.state().stockBooked, 30 ether);
        assertEq(_claims(stock), 30 ether);
        assertEq(sv.totalAssets(), nav);
    }

    function test_aWrittenOffSaleIsRecoveredWhenTheStockComes() public {
        uint256 nav = sv.totalAssets();
        _order(true, 10 ether, 2_950e6);
        vm.warp(block.timestamp + 1 days + 3601);
        vm.prank(OWNER);
        x.writeOffRestock(); // nothing came
        assertEq(sv.totalAssets(), nav - 3_000e6);
        stock.mint(address(sv), 10 ether); // it was refunded after all
        x.syncWindfall();
        assertEq(sv.totalAssets(), nav);
    }

    /// 10-15: the issuer refunded an order 11 h past its expiry. Had the order lapsed by itself and a new
    /// one gone out, that refund would have settled the NEW order as refunded, while the issuer still held
    /// it. Past its deadline an order stays open, so its own late leg closes it, and the next waits.
    function test_anOverdueOrderStaysOpenSoItsLateLegClosesItNotTheNext() public {
        _order(false, 3_000e6, 9.8 ether);
        vm.warp(block.timestamp + 1 days + 12 hours);
        _price(MANTISSA);
        vm.prank(KEEPER);
        vm.expectRevert(StockRestock.RestockUnavailable.selector);
        x.restock(false, 1_000e6, 3.3 ether, 1);
        cash.mint(address(sv), 3_000e6); // the late refund
        vm.expectEmit(address(sv));
        emit StockRestock.RestockRefunded(false, 3_000e6);
        x.settleRestock();
        _order(false, 1_000e6, 3.3 ether);
        assertTrue(x.state().orderOpen, "the next order is open, untouched by the old refund");
    }

    function test_windfallWaitsForAnOpenOrder() public {
        _order(false, 1_000e6, 3.3 ether);
        vm.expectRevert(StockRestock.OrderOpen.selector);
        x.syncWindfall();
    }

    /// Whatever the side, the size and the outcome, once an order closes the vault is worth what it
    /// started with plus what came back less what went, at the mark: never counted twice.
    function testFuzz_aClosedOrderIsCountedOnce(bool sell, uint256 amount, uint256 edgeBps, bool filled) public {
        uint256 nav = sv.totalAssets();
        edgeBps = bound(edgeBps, 0, 290);
        uint256 amountIn;
        uint256 out;
        if (sell) {
            amountIn = bound(amount, 0.01 ether, 30 ether);
            out = _value(amountIn) * (10_000 - edgeBps) / 10_000;
        } else {
            amountIn = bound(amount, 10e6, 7_000e6); // the rest is the margin its stock's short needs
            out = Math.mulDiv(amountIn, 1e30, PRICE) * (10_000 - edgeBps) / 10_000;
        }
        _order(sell, amountIn, out);
        if (filled) {
            if (sell) cash.mint(address(sv), out);
            else stock.mint(address(sv), out);
        } else {
            if (sell) stock.mint(address(sv), amountIn);
            else cash.mint(address(sv), amountIn);
        }
        x.settleRestock();
        assertFalse(x.state().orderOpen);
        uint256 expected = !filled ? nav : sell ? nav - _value(amountIn) + out : nav - amountIn + _value(out);
        assertApproxEqAbs(sv.totalAssets(), expected, 1);
    }
}
