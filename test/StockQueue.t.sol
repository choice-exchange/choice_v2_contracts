// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StockAdmin} from "../src/stock/StockAdmin.sol";
import {StockLib} from "../src/stock/StockLib.sol";
import {StockOps} from "../src/stock/StockOps.sol";
import {StockQueue} from "../src/stock/StockQueue.sol";
import {RedeemEpoch} from "../src/stock/StockTypes.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// The redeem queue on the stock vault harness: OWNER holds every share (10,000 cash and 30 STOCK at
/// 300, so 19,000 of value), the exit fee is 20 bps and the deadline two days.
contract StockQueueTest is StockVaultHarness {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant FEE = 20;

    // ── helpers ───────────────────────────────────────────────────────────

    function _request(address owner_, uint256 shares) internal {
        vm.prank(owner_);
        x.requestRedeem(shares, owner_, owner_);
    }

    function _sharePrice() internal view returns (uint256) {
        return sv.convertToAssets(1e12);
    }

    function _epoch(uint64 id) internal view returns (RedeemEpoch memory e) {
        (,, e) = x.redeemQueue(id);
    }

    // ── requests ──────────────────────────────────────────────────────────

    function test_aRequestEscrowsTheSharesAndChangesNothingElse() public {
        uint256 shares = sv.balanceOf(OWNER) / 10;
        uint256 price = _sharePrice();
        uint256 nav = sv.totalAssets();
        _request(OWNER, shares);
        assertEq(sv.balanceOf(address(sv)), shares);
        assertEq(x.pendingRedeemRequest(0, OWNER), shares);
        assertEq(x.claimableRedeemRequest(0, OWNER), 0);
        assertEq(sv.totalAssets(), nav);
        assertEq(_sharePrice(), price, "queued shares still count");
        (uint64 open,, RedeemEpoch memory e) = x.redeemQueue(1);
        assertEq(open, 1);
        assertEq(e.shares, shares);
        assertEq(e.openedAt, block.timestamp);
    }

    function test_anOperatorOrAnAllowanceMayRequestForTheOwner() public {
        uint256 shares = sv.balanceOf(OWNER) / 10;
        vm.prank(TRADER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, TRADER, 0, shares));
        x.requestRedeem(shares, TRADER, OWNER);

        vm.prank(OWNER);
        sv.approve(TRADER, shares);
        vm.prank(TRADER);
        x.requestRedeem(shares, TRADER, OWNER);
        assertEq(x.pendingRedeemRequest(0, TRADER), shares);
        assertEq(sv.allowance(OWNER, TRADER), 0);

        vm.prank(OWNER);
        x.setOperator(DEPOSITOR, true);
        assertTrue(x.isOperator(OWNER, DEPOSITOR));
        vm.prank(DEPOSITOR);
        x.requestRedeem(shares, OWNER, OWNER);
        assertEq(x.pendingRedeemRequest(0, OWNER), shares);
    }

    function test_requestLimits() public {
        vm.prank(OWNER);
        vm.expectRevert(StockQueue.ZeroShares.selector);
        x.requestRedeem(0, OWNER, OWNER);
        uint256 tiny = sv.convertToShares(5e6);
        uint256 tinyValue = sv.convertToAssets(tiny);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockQueue.RedeemTooSmall.selector, tinyValue, 10e6));
        x.requestRedeem(tiny, OWNER, OWNER);
        vm.prank(GUARDIAN);
        x.pause(StockLib.PAUSE_WITHDRAWALS);
        uint256 shares = sv.balanceOf(OWNER) / 10;
        vm.prank(OWNER);
        vm.expectRevert(StockQueue.QueuePaused.selector);
        x.requestRedeem(shares, OWNER, OWNER);
    }

    function test_theOwnerCannotSweepEscrowedShares() public {
        _request(OWNER, sv.balanceOf(OWNER) / 10);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockAdmin.ProtectedToken.selector, address(sv)));
        x.sweep(address(sv), OWNER, 1);
    }

    // ── cash settlement ───────────────────────────────────────────────────

    function test_anEpochSettlesInCashLessTheFeeAndTheStayersKeepIt() public {
        uint256 shares = sv.balanceOf(OWNER) / 10;
        uint256 gross = sv.convertToAssets(shares);
        uint256 price = _sharePrice();
        _request(OWNER, shares);
        x.settleRedeems();

        uint256 cash = gross * (BPS - FEE) / BPS;
        RedeemEpoch memory e = _epoch(1);
        assertEq(e.status, 2);
        assertEq(e.cash, cash);
        assertEq(sv.balanceOf(address(sv)), 0, "escrow burned");
        assertEq(x.state().cashOwed, cash);
        assertGt(_sharePrice(), price, "the fee stays with those who stay");
        assertEq(x.claimableRedeemRequest(0, OWNER), shares);
        (uint256 c, uint256 st) = x.claimableRedeem(OWNER);
        assertEq(c, cash);
        assertEq(st, 0);

        uint256 before = cash_(OWNER);
        vm.prank(OWNER);
        (uint256 paid,) = x.claimRedeem(OWNER, OWNER);
        assertEq(paid, cash);
        assertEq(cash_(OWNER) - before, cash);
        assertEq(x.state().cashOwed, 0);
        vm.prank(OWNER);
        vm.expectRevert(StockQueue.NothingToClaim.selector);
        x.claimRedeem(OWNER, OWNER);
    }

    function test_cashSettlementWaitsForTheCash() public {
        uint256 shares = sv.balanceOf(OWNER) * 6 / 10; // 11,400 against 10,000 of cash
        _request(OWNER, shares);
        uint256 cash = sv.convertToAssets(shares) * (BPS - FEE) / BPS;
        vm.expectRevert(abi.encodeWithSelector(StockQueue.CashShortForQueue.selector, cash, 10_000e6));
        x.settleRedeems();
    }

    function test_instantWithdrawalsCannotTakeTheCashTheQueueNeeds() public {
        cash.mint(DEPOSITOR, 5_000e6);
        vm.startPrank(DEPOSITOR);
        cash.approve(address(sv), type(uint256).max);
        sv.deposit(5_000e6, DEPOSITOR);
        vm.stopPrank();
        // OWNER queues 70%: about 13,300 of the 15,000 cash is spoken for.
        uint256 shares = sv.balanceOf(OWNER) * 7 / 10;
        _request(OWNER, shares);
        uint256 free = 15_000e6 - sv.convertToAssets(shares) - 1;
        uint256 max = sv.maxWithdraw(DEPOSITOR);
        assertApproxEqAbs(max, free, 2);
        vm.prank(DEPOSITOR);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, DEPOSITOR, 5_000e6, max));
        sv.withdraw(5_000e6, DEPOSITOR, DEPOSITOR);
    }

    function test_settlementObeysThePauseButClaimsDoNot() public {
        uint256 shares = sv.balanceOf(OWNER) / 10;
        _request(OWNER, shares);
        x.settleRedeems();
        vm.prank(GUARDIAN);
        x.pause(StockLib.PAUSE_WITHDRAWALS);
        vm.prank(OWNER);
        (uint256 paid,) = x.claimRedeem(OWNER, OWNER);
        assertGt(paid, 0, "claims are never paused");

        vm.prank(OWNER);
        x.unpause(StockLib.PAUSE_WITHDRAWALS);
        _request(OWNER, shares);
        vm.prank(GUARDIAN);
        x.pause(StockLib.PAUSE_WITHDRAWALS);
        vm.expectRevert(abi.encodeWithSelector(StockOps.IsPaused.selector, StockLib.PAUSE_WITHDRAWALS));
        x.settleRedeems();
    }

    function test_twoControllersSplitAnEpochExactly() public {
        uint256 a = sv.balanceOf(OWNER) / 7;
        uint256 b = sv.balanceOf(OWNER) / 9 + 3;
        vm.prank(OWNER);
        assertTrue(sv.transfer(DEPOSITOR, b));
        _request(OWNER, a);
        _request(DEPOSITOR, b);
        x.settleRedeems();
        uint256 total = _epoch(1).cash;
        vm.prank(OWNER);
        (uint256 ca,) = x.claimRedeem(OWNER, OWNER);
        vm.prank(DEPOSITOR);
        (uint256 cb,) = x.claimRedeem(DEPOSITOR, DEPOSITOR);
        assertEq(ca + cb, total, "every unit paid");
        assertEq(x.state().cashOwed, 0);
        assertApproxEqAbs(ca * b, cb * a, a + b, "pro rata");
    }

    function test_aLaterRequestRollsTheSettledOneIntoTheClaim() public {
        uint256 shares = sv.balanceOf(OWNER) / 10;
        _request(OWNER, shares);
        x.settleRedeems();
        uint256 first = _epoch(1).cash;
        _request(OWNER, shares);
        assertEq(x.claimableRedeemRequest(0, OWNER), shares, "the first is claimable");
        assertEq(x.pendingRedeemRequest(0, OWNER), shares, "the second is queued");
        x.settleRedeems();
        uint256 second = _epoch(2).cash;
        vm.prank(OWNER);
        (uint256 paid,) = x.claimRedeem(OWNER, OWNER);
        assertEq(paid, first + second);
    }

    function test_anOperatorClaimsToAnyReceiver() public {
        _request(OWNER, sv.balanceOf(OWNER) / 10);
        x.settleRedeems();
        vm.prank(TRADER);
        vm.expectRevert(StockQueue.NotAuthorized.selector);
        x.claimRedeem(OWNER, TRADER);
        vm.prank(OWNER);
        x.setOperator(DEPOSITOR, true);
        uint256 before = cash_(TRADER);
        vm.prank(DEPOSITOR);
        (uint256 paid,) = x.claimRedeem(OWNER, TRADER);
        assertEq(cash_(TRADER) - before, paid);
    }

    // ── in kind ───────────────────────────────────────────────────────────

    function test_inKindPaysAShareOfTheStockAndTheCash() public {
        uint256 shares = sv.balanceOf(OWNER) / 2;
        uint256 supply = sv.totalSupply() + 1e6;
        _request(OWNER, shares);
        vm.prank(KEEPER);
        x.startInKind();
        uint256 stockOut = Math.mulDiv(30 ether, shares, supply);
        uint256 cashOut = Math.mulDiv(10_000e6, shares, supply) * (BPS - FEE) / BPS;
        RedeemEpoch memory e = _epoch(1);
        assertEq(e.status, 2, "no short, so no debt");
        assertEq(e.stock, stockOut);
        assertEq(e.cash, cashOut);
        assertEq(x.state().stockBooked, 30 ether - stockOut);

        vm.prank(OWNER);
        (uint256 c, uint256 st) = x.claimRedeem(OWNER, OWNER);
        assertEq(c, cashOut);
        assertEq(st, stockOut);
        assertEq(stock.balanceOf(OWNER), stockOut);
        assertEq(x.state().stockOwed, 0);
        assertEq(x.state().cashOwed, 0);
    }

    function test_anyoneSettlesInKindOnceOverdue() public {
        _request(OWNER, sv.balanceOf(OWNER) / 10);
        vm.prank(TRADER);
        vm.expectRevert(abi.encodeWithSelector(StockQueue.QueueNotOverdue.selector, T_REGULAR + 2 days));
        x.startInKind();
        vm.warp(T_REGULAR + 2 days);
        _price(MANTISSA);
        vm.prank(TRADER);
        x.startInKind();
        assertEq(_epoch(1).status, 2);
    }

    function test_theShortsShareIsADebtPaidOnceTheShortIsCut() public {
        _hedge(300e18); // short 30, its margin out of the cash
        // Take the free cash out instantly, so the debt cannot be paid until the short is cut.
        uint256 free = sv.maxWithdraw(OWNER);
        vm.prank(OWNER);
        sv.withdraw(free, OWNER, OWNER);
        _request(OWNER, sv.balanceOf(OWNER) / 2);
        vm.prank(KEEPER);
        x.startInKind();
        (uint64 open, uint64 unwinding, RedeemEpoch memory e) = x.redeemQueue(1);
        assertEq(open, 2);
        assertEq(unwinding, 1);
        assertEq(e.status, 1);
        assertGt(e.debt, 0);
        assertEq(x.state().debtOwed, e.debt, "owed, so out of the vault's value");
        vm.expectRevert(abi.encodeWithSelector(StockQueue.CashShortForQueue.selector, e.debt, 0));
        x.finishInKind();

        // Epochs settle in order.
        uint256 more = sv.balanceOf(OWNER) / 10;
        vm.prank(OWNER);
        assertTrue(sv.transfer(DEPOSITOR, more));
        _request(DEPOSITOR, more);
        vm.expectRevert(abi.encodeWithSelector(StockQueue.UnwindPending.selector, 1));
        x.settleRedeems();

        // The stock went out, so the hedge covers half the short and its margin comes back.
        vm.roll(block.number + 1);
        _hedge(300e18);
        // Covered to the quantity tick: the booked half rounds up past 15 by a unit.
        assertApproxEqAbs(x.state().shortConfirmed, 15 ether, 1e15);
        uint256 priceBefore = _sharePrice();
        x.finishInKind();
        // The debt left the share price when it was owed: paying it moves nothing.
        assertApproxEqAbs(_sharePrice(), priceBefore, 1);
        assertEq(x.state().debtOwed, 0);
        e = _epoch(1);
        assertEq(e.status, 2);
        assertEq(e.debt, 0);
        vm.prank(OWNER);
        (uint256 c, uint256 st) = x.claimRedeem(OWNER, OWNER);
        assertEq(c, e.cash, "its cash now and its debt, paid");
        assertEq(st, e.stock);
        assertApproxEqRel(st, 15 ether, 1e9, "half the stock, less the virtual shares' part");
    }

    function test_aRequestWaitsWhileItsEarlierEpochOwesItsDebt() public {
        _hedge(300e18);
        uint256 free = sv.maxWithdraw(OWNER);
        vm.prank(OWNER);
        sv.withdraw(free, OWNER, OWNER);
        _request(OWNER, sv.balanceOf(OWNER) / 2);
        vm.prank(KEEPER);
        x.startInKind();
        uint256 more = sv.balanceOf(OWNER) / 10;
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockQueue.EarlierRequestUnsettled.selector, 1));
        x.requestRedeem(more, OWNER, OWNER);
    }

    // ── fuzz ──────────────────────────────────────────────────────────────

    /// Whatever the split between two leavers and the mode: those who stay never lose share price,
    /// every unit settled is claimed exactly, and nothing stays owed.
    function testFuzz_anEpochNeverCostsThoseWhoStay(uint256 a, uint256 b, bool inKind) public {
        uint256 all = sv.balanceOf(OWNER);
        // Together at most half the shares: about 9,500 against 10,000 of cash.
        a = bound(a, all / 1000, all / 4);
        b = bound(b, all / 1000, all / 4);
        vm.prank(OWNER);
        assertTrue(sv.transfer(DEPOSITOR, b));
        uint256 price = _sharePrice();
        _request(OWNER, a);
        _request(DEPOSITOR, b);
        if (inKind) {
            vm.prank(KEEPER);
            x.startInKind();
        } else {
            x.settleRedeems();
        }
        assertGe(_sharePrice(), price);
        RedeemEpoch memory e = _epoch(1);
        (uint256 cashTotal, uint256 stockTotal) = (e.cash, e.stock);
        vm.prank(OWNER);
        (uint256 c1, uint256 s1) = x.claimRedeem(OWNER, OWNER);
        vm.prank(DEPOSITOR);
        (uint256 c2, uint256 s2) = x.claimRedeem(DEPOSITOR, DEPOSITOR);
        assertEq(c1 + c2, cashTotal);
        assertEq(s1 + s2, stockTotal);
        assertEq(x.state().cashOwed, 0);
        assertEq(x.state().stockOwed, 0);
        assertGe(_sharePrice(), price);
    }

    function cash_(address who) internal view returns (uint256) {
        return cash.balanceOf(who);
    }
}
