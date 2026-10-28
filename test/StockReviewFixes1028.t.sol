// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StockLib} from "../src/stock/StockLib.sol";
import {StockModule} from "../src/stock/StockModule.sol";
import {StockOps} from "../src/stock/StockOps.sol";
import {StockRestock} from "../src/stock/StockRestock.sol";
import {StockVault} from "../src/stock/StockVault.sol";
import {Refusal, StockConfig} from "../src/stock/StockTypes.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// The 10-28 review's findings, each first proven against the unfixed code (the share price moved, the
/// lock was rolled, the queue's cash was spent) and kept here as the regression test that it no longer
/// is. The fixing lane's two are in `StockFixing.t.sol`. OWNER holds every share: 10,000 cash and 30
/// STOCK at 300, so 19,000 of value.
contract StockReviewFixes1028Test is StockVaultHarness {
    address internal constant ATTACKER = address(0xA77A);

    function setUp() public override {
        super.setUp();
        vm.prank(OWNER);
        x.setRestockMemo('{"did_id":"\x04","give":"\x01","want":"\x02",\x03}');
    }

    function _order(bool sell, uint256 amountIn, uint256 limitOut) internal {
        vm.prank(KEEPER);
        x.restock(sell, amountIn, limitOut, 1);
    }

    // ── a restock order is valued at what it closes at ────────────────────

    /// A buy fills exactly at its limit or is refunded. Once the mark is past the limit the refund is what
    /// comes, so the order is worth its cash, not its stock: counted as stock, an exit then would take the
    /// difference from everyone who stays.
    function test_aBuyThePriceRanPastIsCountedAsItsRefund() public {
        _order(false, 3_000e6, 9.8 ether); // a limit of 306.12
        _price(30_300_000); // 303: under the limit, so it fills
        assertEq(sv.totalAssets(), 7_000e6 + 9_090e6 + 2_969.4e6, "its stock at the mark");
        _price(30_900_000); // 309: past it, so the issuer refunds
        assertEq(sv.totalAssets(), 7_000e6 + 9_270e6 + 3_000e6, "its cash, not 3,028.2 of stock it will not get");
        cash.mint(address(sv), 3_000e6); // the refund
        assertEq(sv.totalAssets(), 7_000e6 + 9_270e6 + 3_000e6, "counted once");
        x.settleRestock();
        assertEq(sv.totalAssets(), 7_000e6 + 9_270e6 + 3_000e6);
    }

    /// A sale paid 50 under the mark: an exit before anyone settles it is priced after it settles, so the
    /// 50 is everyone's, not only the stayers'.
    function test_anArrivedLegIsSettledBeforeAnExitIsPriced() public {
        _order(true, 10 ether, 2_950e6);
        cash.mint(address(sv), 2_950e6); // paid at the limit; nobody has settled it
        uint256 supply = sv.totalSupply();
        vm.prank(OWNER);
        uint256 burned = sv.withdraw(1_000e6, OWNER, OWNER);
        assertFalse(x.state().orderOpen, "settled first");
        assertApproxEqRel(burned, Math.mulDiv(1_000e6, supply, 18_950e6), 1e12, "priced at 18,950, not 19,000");
        assertEq(sv.totalAssets(), 17_950e6);
    }

    function test_aQueuedExitAlsoSettlesAnArrivedLegFirst() public {
        _order(true, 10 ether, 2_950e6);
        cash.mint(address(sv), 2_950e6);
        uint256 shares = sv.balanceOf(OWNER) / 10;
        vm.prank(OWNER);
        x.requestRedeem(shares, OWNER, OWNER);
        x.settleRedeems();
        assertFalse(x.state().orderOpen);
    }

    // ── a buy's limit is bounded both ways ────────────────────────────────

    /// Asking for far more stock than the cash buys never fills, and the order was valued at the stock it
    /// asked for: the keeper could lift the share price until the refund.
    function test_aBuyMayNotAskForMoreStockThanItsCashBuys() public {
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockRestock.LimitOutOfBand.selector, 4_500e6, 3_090e6));
        x.restock(false, 3_000e6, 15 ether, 1); // 4,500 of stock for 3,000
        _order(false, 3_000e6, 10.3 ether); // 3,090: the band's top
    }

    // ── nobody deposits into another's lock ───────────────────────────────

    /// A deposit restarts its receiver's lock. Had a stranger been able to deposit for a holder, dust paid
    /// in every `depositLock` would have kept the holder's newest shares locked for as long as it went on.
    function test_onlyTheReceiverOrItsOperatorDepositsForIt() public {
        StockConfig memory c = _cfg();
        c.depositLock = 300;
        _setCfg(c);
        vm.prank(OWNER);
        x.setDepositor(ATTACKER, true);
        cash.mint(DEPOSITOR, 100e6);
        cash.mint(ATTACKER, 1e6);
        vm.startPrank(DEPOSITOR);
        cash.approve(address(sv), type(uint256).max);
        uint256 shares = sv.deposit(100e6, DEPOSITOR);
        vm.stopPrank();

        vm.warp(block.timestamp + 299);
        _price(MANTISSA);
        vm.startPrank(ATTACKER);
        cash.approve(address(sv), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(StockVault.NotOperator.selector, DEPOSITOR, ATTACKER));
        sv.deposit(1e6, DEPOSITOR); // a second before the lock ends
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _price(MANTISSA);
        vm.prank(DEPOSITOR);
        sv.redeem(shares, DEPOSITOR, DEPOSITOR); // free on time

        vm.prank(DEPOSITOR);
        x.setOperator(ATTACKER, true);
        vm.prank(ATTACKER);
        sv.deposit(1e6, DEPOSITOR); // an operator it approved may
    }

    // ── the queue's cash is kept from fills ───────────────────────────────

    /// A queued epoch's cash is kept like the reserve. Only instant withdrawals respected it, so a fill
    /// paying cash out could spend what the redeemers wait for and push them into stock.
    function test_aFillCannotSpendCashTheQueueIsWaitingFor() public {
        uint256 half = sv.balanceOf(OWNER) / 2; // 9,500 of value
        vm.prank(OWNER);
        x.requestRedeem(half, OWNER, OWNER);
        _expectRefusal(Refusal.Reserve);
        _swap(false, true, 6.6 ether); // ~1,975 out, plus its short's margin: over the 500 left above the queue
        _swap(false, true, 1 ether); // ~300 and its margin fit
    }

    // ── funding may stay unsettled for a day at most ──────────────────────

    /// A refused settlement leaves the value without the funding accrued since. It is tolerated, so a short
    /// under its margin ratio does not freeze exits at once, but for a day from the first refusal only.
    function test_fundingMayStayUnsettledForADayAtMost() public {
        _hedge(PRICE);
        exchange.setFailDecrease(true);
        cash.mint(OWNER, 2e6);
        vm.prank(OWNER);
        sv.deposit(1e6, OWNER); // the first refusal starts the clock
        uint256 since = vm.getBlockTimestamp(); // not block.timestamp, which via-ir reads after the warps
        vm.warp(since + 1 days);
        _price(MANTISSA);
        vm.prank(OWNER);
        sv.deposit(1e6, OWNER); // a day on: still tolerated
        vm.warp(since + 1 days + 1);
        _price(MANTISSA);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockOps.FundingStale.selector, since));
        sv.withdraw(1e6, OWNER, OWNER);

        exchange.setFailDecrease(false);
        vm.prank(OWNER);
        sv.withdraw(1e6, OWNER, OWNER); // settled, so the clock is cleared
        exchange.setFailDecrease(true);
        vm.prank(OWNER);
        sv.withdraw(1e6, OWNER, OWNER); // and the next refusal starts a new one
    }

    // ── an unreadable subaccount is a named refusal ───────────────────────

    /// The hedge subaccount's cash is in the value, and the precompile reverts on a negative balance. The
    /// value is then refused by name, and the ERC-4626 limits read zero, as they must, rather than revert.
    function test_anUnreadableSubaccountIsRefusedByName() public {
        exchange.setFailSubaccountRead(true);
        vm.expectRevert(StockLib.SubaccountUnreadable.selector);
        sv.totalAssets();
        assertEq(sv.maxDeposit(OWNER), 0);
        assertEq(sv.maxWithdraw(OWNER), 0);
        assertEq(sv.maxRedeem(OWNER), 0);
        assertFalse(sv.navReady());
    }

    // ── nobody books a gift but the keeper ────────────────────────────────

    /// A booked gift moves the share price, past `navJumpBps` stopping every deposit and exit until the
    /// owner accepts it: anyone could freeze the vault for the price of the gift.
    function test_onlyTheKeeperBooksAWindfall() public {
        stock.mint(address(sv), 30 ether); // a gift of 9,000
        vm.prank(ATTACKER);
        vm.expectRevert(StockModule.NotKeeper.selector);
        x.syncWindfall();
        vm.prank(KEEPER);
        x.syncWindfall();
        assertEq(x.state().stockBooked, 60 ether);
    }

    /// Settling an order books its own leg, at most `restockSlippageBps` over what it asked for, so a gift
    /// sent with the leg waits for the keeper too.
    function test_settlingAnOrderBooksItsLegButNotAGiftWithIt() public {
        _order(false, 3_000e6, 9.8 ether);
        stock.mint(address(sv), 40 ether); // 10 delivered, better than the limit, and 30 given
        x.settleRestock();
        assertEq(x.state().stockBooked, 30 ether + 10.094 ether, "the leg, up to 3% over its 9.8");
        vm.prank(KEEPER);
        x.syncWindfall();
        assertEq(x.state().stockBooked, 70 ether);
    }
}
