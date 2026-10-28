// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IExchangeDerivatives} from "../src/interfaces/IExchangeDerivatives.sol";
import {StockAdmin} from "../src/stock/StockAdmin.sol";
import {StockHedge} from "../src/stock/StockHedge.sol";
import {StockLib} from "../src/stock/StockLib.sol";
import {StockPricing} from "../src/stock/StockPricing.sol";
import {StockRestock} from "../src/stock/StockRestock.sol";
import {StockVault} from "../src/stock/StockVault.sol";
import {Fill, RedeemEpoch, Refusal, StockConfig} from "../src/stock/StockTypes.sol";
import {LazerBuilder} from "./utils/LazerBuilder.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// The 10-15 review's High findings, each first proven against the unfixed code (the attack went
/// through) and kept here as the regression test that it no longer does.
contract StockReviewFixesTest is StockVaultHarness {
    address internal constant ATTACKER = address(0xA77A);

    // ── the owner cannot redirect restocking to itself ────────────────────

    function test_theIssuerIsTheRegistrysOnly() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockAdmin.NotRegistryIssuer.selector, ATTACKER));
        x.setRoles(ATTACKER, GUARDIAN, ATTACKER);
        vm.prank(OWNER);
        x.setRoles(KEEPER, GUARDIAN, address(0)); // none stops memo restocking
        vm.prank(OWNER);
        x.setRestockMemo('{"did_id":"\x04",\x01\x02\x03}');
        vm.prank(KEEPER);
        vm.expectRevert(StockRestock.RestockUnavailable.selector);
        x.restock(false, 1_000e6, 3.3 ether, 1);
    }

    function test_theTemplateCannotNameAnotherPayeeOrExpiry() public {
        vm.startPrank(OWNER);
        vm.expectRevert(StockRestock.BadMemo.selector);
        x.setRestockMemo("\x01\x02\x03\x04"); // the vault, but not as did_id
        vm.expectRevert(StockRestock.BadMemo.selector);
        x.setRestockMemo('{"did_id":"0xa77a","did_id":"\x04",\x01\x02\x03}'); // a second payee
        vm.expectRevert(StockRestock.BadMemo.selector);
        x.setRestockMemo('{"did_id":"\x04","expiry_days":9,\x01\x02\x03}'); // its own expiry
        x.setRestockMemo('{"did_id":"\x04",\x01\x02\x03}');
        vm.stopPrank();
    }

    function test_theMemoPaysTheVaultInTheConfiguredUnit() public {
        StockConfig memory c = _cfg();
        c.restockExpiryUnit = 1 hours;
        _setCfg(c);
        vm.prank(OWNER);
        x.setRestockMemo('{"did_id":"\x04","offer":"\x01","request":"\x02",\x03}');
        bytes memory memo = abi.encodePacked(
            '{"did_id":"',
            vm.toLowercase(vm.toString(address(sv))),
            '","offer":"1000000000","request":"3300000000000000000","expiry_hours":2}'
        );
        vm.expectCall(address(cash), abi.encodePacked(abi.encodeCall(IERC20.transfer, (ISSUER, 1_000e6)), memo));
        vm.prank(KEEPER);
        x.restock(false, 1_000e6, 3.3 ether, 2);
    }

    // ── a halt always has a way out ───────────────────────────────────────

    function test_aHaltAcrossABigMoveIsAcceptedAtAStatedPrice() public {
        x.poke(); // anchored at 300
        vm.prank(GUARDIAN);
        x.haltAction();
        _price(MANTISSA * 14 / 10); // reopens 40% higher
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockPricing.ActionMove.selector, 420e18, PRICE));
        x.acceptAction(1e12, 3000);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockPricing.ActionMove.selector, 420e18, 400e18));
        x.acceptActionAt(1e12, 100, 400e18); // the owner's expectation is still checked
        vm.prank(OWNER);
        x.acceptActionAt(1e12, 100, 420e18);
        assertFalse(x.actionPending());
        assertEq(x.state().anchorPrice, 420e18);
    }

    // ── a split in the feed first halts instead of re-anchoring ───────────

    function test_aSplitSizedJumpHaltsInsteadOfReanchoring() public {
        x.poke();
        _price(MANTISSA / 4);
        x.poke(); // 75% move: halted at once, no reanchorDelay to wait out
        assertTrue(x.actionPending());
        assertEq(x.state().anchorPrice, PRICE);
        assertEq(uint256(sv.quoteFill(true, 300e6, true, "").reason), uint256(Refusal.Action));
    }

    function test_aBreakerSizedJumpStillReanchorsAfterTheDelay() public {
        x.poke();
        _price(MANTISSA * 12 / 10); // +20%: past the 15% breaker, under the 30% action bound
        x.poke();
        vm.warp(block.timestamp + 301);
        _price(MANTISSA * 12 / 10);
        x.poke();
        assertFalse(x.actionPending());
        assertEq(x.state().anchorPrice, 360e18);
    }

    // ── a signed update must carry what protects the vault ────────────────

    function test_anUpdateWithoutAnExponentIsNeverStored() public {
        x.poke();
        uint64 ts = uint64(block.timestamp) * 1e6 + ++nonce;
        bytes memory p = abi.encodePacked(
            LazerBuilder.PAYLOAD_MAGIC, ts, LazerBuilder.FIXED_RATE_200, uint8(1), FEED, uint8(2), uint8(0), MANTISSA
        );
        p = abi.encodePacked(p, uint8(12), uint8(1), ts);
        assertEq(store.update(LazerBuilder.sign(SIGNER_KEY, p)), 0);
        assertEq(x.state().anchorPrice, PRICE);
    }

    // ── the margin top-up counts the short's loss ─────────────────────────

    function _equity() internal view returns (uint256 margin, int256 equity, uint256 target) {
        IExchangeDerivatives.DerivativePosition memory p = exchange.subaccountPositions(_sub())[0];
        uint256 mark = 345e18;
        margin = p.margin;
        equity = int256(p.margin) + (int256(p.entryPrice) - int256(mark)) * int256(p.quantity) / 1e18;
        target = Math.mulDiv(p.quantity, mark, 1e18) * 10 / 30;
    }

    function test_anyoneTopsUpAShortWhoseEquityIsLow() public {
        _hedge(PRICE);
        _price(MANTISSA * 115 / 100); // +15% at 3x: margin untouched, equity about half the target
        (uint256 before,,) = _equity();
        x.topUpMargin();
        (uint256 margin, int256 equity, uint256 target) = _equity();
        assertGt(margin, before);
        assertEq(uint256(equity), target, "equity back at the target leverage");
    }

    function test_theKeeperTopsUpBelowTheTargetAnyoneOnlyBelow70Percent() public {
        _hedge(PRICE);
        _price(MANTISSA * 103 / 100); // +3%: equity under the target, above 70% of it
        vm.expectRevert(StockHedge.MarginHealthy.selector);
        x.topUpMargin();
        vm.prank(KEEPER);
        x.topUpMargin();
    }

    // ── 10-16: Lows ───────────────────────────────────────────────────────

    /// The overnight market trades: a price it moved to and then left is as stale as one in session.
    function test_anOvernightPricedAsClosedNeedsAFreshPriceOnceItMoves() public {
        StockConfig memory c = _cfg();
        c.overnightLive = false;
        _setCfg(c);
        vm.warp(WED + 6 hours); // 02:00 New York; the close was Tuesday 20:00 (WED + 0h)
        LazerBuilder.Feed memory f = _feed(MANTISSA);
        f.feedTimestampUs = uint64(WED + 1 hours) * 1e6; // traded at 21:00, nothing since
        store.update(_update(f));
        assertEq(uint256(sv.quoteFill(true, 300e6, true, "").reason), uint256(Refusal.Stale));

        _price(MANTISSA);
        Fill memory q = sv.quoteFill(true, 300e6, true, "");
        assertEq(uint256(q.reason), uint256(Refusal.None));
        assertTrue(q.closed);
        assertEq(q.spreadBps, 80, "still priced as closed");
    }

    function test_aQueuedRequestPaysTheFeeItWasMadeUnder() public {
        uint256 shares = sv.balanceOf(OWNER) / 10;
        uint256 gross = sv.convertToAssets(shares);
        vm.prank(OWNER);
        x.requestRedeem(shares, OWNER, OWNER);
        StockConfig memory c = _cfg();
        c.exitFeeBps = 200; // raised after a request that cannot be cancelled
        _setCfg(c);
        x.settleRedeems();
        (,, RedeemEpoch memory e) = x.redeemQueue(1);
        assertEq(e.feeBps, 20);
        assertEq(e.cash, gross * (10_000 - 20) / 10_000);
    }

    function test_aQueueSettlementMovesTheBreakersLastPrice() public {
        StockConfig memory c = _cfg();
        c.navJumpBps = 10;
        _setCfg(c);
        uint256 shares = sv.balanceOf(OWNER) / 2;
        vm.prank(OWNER);
        x.requestRedeem(shares, OWNER, OWNER);
        uint256 before = sv.convertToAssets(1e12);
        x.settleRedeems(); // the 20 bps fee on half the vault lifts the share price about 20 bps
        uint256 price = sv.convertToAssets(1e12);
        assertGt(price, before * (10_000 + 15) / 10_000);
        assertEq(x.state().lastSharePrice, price);

        cash.mint(DEPOSITOR, 100e6);
        vm.startPrank(DEPOSITOR);
        cash.approve(address(sv), type(uint256).max);
        sv.deposit(100e6, DEPOSITOR); // not a NavJump
        vm.stopPrank();
    }

    function test_maxViewsAreZeroWhenTheCallWouldRevert() public {
        assertGt(sv.maxDeposit(DEPOSITOR), 0);
        assertGt(sv.maxWithdraw(OWNER), 0);
        assertGt(sv.maxRedeem(OWNER), 0);

        vm.warp(block.timestamp + 10); // in session, and the price is 10 s old
        assertEq(sv.maxDeposit(DEPOSITOR), 0);
        assertEq(sv.maxMint(DEPOSITOR), 0);
        assertEq(sv.maxWithdraw(OWNER), 0);
        assertEq(sv.maxRedeem(OWNER), 0);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Stale));
        sv.withdraw(1e6, OWNER, OWNER);

        vm.warp(SAT + 12 hours); // closed, on Friday's close
        LazerBuilder.Feed memory f = _feed(MANTISSA);
        f.feedTimestampUs = uint64(SAT) * 1e6 - 200_000;
        store.update(_update(f));
        assertEq(sv.maxDeposit(DEPOSITOR), 0);
        assertEq(sv.maxWithdraw(OWNER), 0);
    }

    // ── 10-17: the last Lows ──────────────────────────────────────────────

    /// A liquidation counts at once: fills are judged on the position the exchange has now, not on the
    /// short last confirmed.
    function test_aLiquidationCountsBeforeAnyoneConfirmsIt() public {
        StockConfig memory c = _cfg();
        _unhedgedCap(c, 5_000e6);
        _setCfg(c);
        _hedge(PRICE); // short 30: the holding is hedged
        assertEq(uint256(sv.quoteFill(false, 1 ether, true, "").reason), uint256(Refusal.None));
        exchange.setQuantity(_sub(), MARKET, 0); // liquidated, and nobody has confirmed it
        assertEq(x.state().shortConfirmed, 30 ether);
        assertEq(uint256(sv.quoteFill(false, 1 ether, true, "").reason), uint256(Refusal.Unhedged));
        // A fill that shrinks the now unhedged holding still goes through.
        assertEq(uint256(sv.quoteFill(true, 300e6, true, "").reason), uint256(Refusal.None));
    }

    /// A signed update handed to a fill replaces the stored price only with news since it: a later batch
    /// whose feed has not moved since the stored price was stamped is ignored.
    function test_aFillerCannotChooseAnUpdateWithNoNewsSinceTheStoredPrice() public {
        _price(MANTISSA);
        uint64 storedAt = uint64(block.timestamp) * 1e6 + nonce;
        LazerBuilder.Feed memory f = _feed(MANTISSA * 103 / 100);
        f.feedTimestampUs = storedAt;
        assertEq(sv.quoteFill(true, 300e6, true, _update(f)).price, PRICE);
        assertEq(sv.quoteFill(true, 300e6, true, _update(_feed(MANTISSA * 103 / 100))).price, 309e18);
    }

    /// A closure past the calendar's lookback (the guardian can make one) refuses a frozen price instead
    /// of reverting every call, the swap hook's and the ERC-4626 views' included.
    function test_aClosurePastTheLookbackRefusesInsteadOfReverting() public {
        uint32 first = uint32(WED / 1 days);
        uint32[] memory dayList = new uint32[](12);
        for (uint32 i; i < 12; ++i) {
            dayList[i] = first + i;
        }
        vm.prank(GUARDIAN);
        calendar.closeDays(dayList);
        vm.warp(uint256(first + 11) * 1 days + 15 hours);
        assertEq(uint256(sv.quoteFill(true, 300e6, true, "").reason), uint256(Refusal.Stale));
        assertEq(sv.maxDeposit(DEPOSITOR), 0);
        assertEq(sv.maxWithdraw(OWNER), 0);
    }

    /// A jump noted and then gone unseen cannot re-anchor a later, different jump on its first poke.
    function test_aStaleJumpNoteDoesNotReanchorADifferentJump() public {
        x.poke(); // anchored at 300
        _price(MANTISSA * 12 / 10);
        x.poke(); // +20%: noted
        vm.warp(block.timestamp + 1 hours); // it went away unseen; now the price falls instead
        _price(MANTISSA * 8 / 10);
        x.poke(); // -20%: a different jump, whose clock starts now
        assertEq(x.state().anchorPrice, PRICE);
        assertEq(x.state().jumpPrice, 240e18);
        vm.warp(block.timestamp + 301);
        _price(MANTISSA * 8 / 10);
        x.poke();
        assertEq(x.state().anchorPrice, 240e18);
    }

    function test_aMigrationTakesTheNewMarketsTicks() public {
        vm.prank(GUARDIAN);
        x.haltAction();
        vm.startPrank(OWNER);
        string memory next = "0x00000000000000000000000000000000000000000000000000000000000000cc";
        vm.expectRevert(StockLib.BadConfig.selector);
        x.migrateMarket(next, 0, 1e16);
        x.migrateMarket(next, 1e16, 1e17);
        vm.stopPrank();
        assertEq(x.config().qtyTick, 1e16);
        assertEq(x.config().priceTick, 1e17);
        assertEq(x.state().marketId, next);
    }

    /// A restock buy leaves the cash the open redeem epoch is waiting for.
    function test_aRestockBuyLeavesTheQueuedExitsCash() public {
        vm.prank(OWNER);
        x.setRestockMemo('{"did_id":"\x04",\x01\x02\x03}');
        uint256 shares = sv.balanceOf(OWNER) / 4;
        vm.prank(OWNER);
        x.requestRedeem(shares, OWNER, OWNER);
        // 6,000 for 20 at 300, whose short needs 2,000 of margin: room for that, but not for the queue too.
        uint256 needed = 6_000e6 + sv.convertToAssets(shares) + 2_000e6;
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.CashShort.selector, needed, 10_000e6));
        x.restock(false, 6_000e6, 20 ether, 1);
        vm.prank(KEEPER);
        x.restock(false, 3_000e6, 10 ether, 1);
        x.settleRedeems();
    }

    /// Under 30%, a split accepted before the feed shows it is caught by the bound the ratio itself sets,
    /// whatever bound the owner passes.
    function test_aSmallSplitAcceptedEarlyIsCaught() public {
        x.poke();
        uint256 r = 0.8e12; // 5:4
        vm.prank(UPDATER);
        ratios.setRatio(address(stock), r);
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockPricing.MoveBoundTooWide.selector, 1250, 2500));
        x.acceptAction(uint56(r), 1250);
        vm.expectRevert(abi.encodeWithSelector(StockPricing.ActionMove.selector, 375e18, PRICE));
        x.acceptAction(uint56(r), 1000);
        vm.stopPrank();
        _price(MANTISSA * 4 / 5); // the feed splits: 240 a share is 300 a token at 0.8
        vm.prank(OWNER);
        x.acceptAction(uint56(r), 1000);
        assertEq(x.context().tokenPerShare, r);
    }

    /// Mainnet 10-16: a covered short paid 10,082,710.60217 units into the hedge subaccount, which the
    /// precompile answered as 10,082,711. Withdrawing that was refused, so the cash never came back, and
    /// every hedge that had to bring cash back reverted.
    function test_aSubaccountBalanceTheExchangeRoundsUpStillComesBack() public {
        uint256 n = block.number; // via-IR reads `block.number` once per function: roll by explicit numbers
        _hedge(PRICE); // short 30, confirmed at n + 1
        vm.roll(n + 2);
        _swap(true, false, 10 ether); // a taker takes 10: the short is 10 over
        vm.prank(KEEPER);
        assertTrue(x.syncHedge()); // cover 10, reduce-only
        vm.roll(n + 3);
        exchange.endBlock(PRICE); // its margin comes back to the subaccount
        exchange.addDust(_sub(), exchange.cashScale() * 6 / 10); // a fraction over half, which reads rounded up
        bytes32 sub = keccak256(bytes(_sub()));
        uint256 back = exchange.depositTotal(sub);
        assertGt(back, 0);
        uint256 booked = x.state().cashBooked;
        x.confirmHedge();
        assertEq(exchange.depositTotal(sub), 0, "every whole unit came back");
        assertEq(x.state().cashBooked, booked + back);
        vm.roll(n + 4);
        vm.prank(KEEPER);
        assertFalse(x.syncHedge(), "in the band, and nothing to bring back: no revert");
    }

    /// The shares a deposit mints stay put for the lock, so nobody can deposit, push a newer price and
    /// withdraw the difference. Shares held before are free, so a later dust deposit locks only the dust.
    function test_aDepositsSharesAreLockedButOlderOnesAreNot() public {
        StockConfig memory c = _cfg();
        c.depositLock = 300;
        _setCfg(c);
        cash.mint(DEPOSITOR, 100e6);
        cash.mint(OWNER, 1e6);
        vm.startPrank(DEPOSITOR);
        cash.approve(address(sv), type(uint256).max);
        uint256 shares = sv.deposit(100e6, DEPOSITOR);
        bytes memory locked =
            abi.encodeWithSelector(StockVault.SharesLocked.selector, shares, uint256(block.timestamp + 300));
        assertEq(sv.maxRedeem(DEPOSITOR), 0);
        assertEq(sv.maxWithdraw(DEPOSITOR), 0);
        // ERC-4626's own check refuses first, on the maximum the lock leaves.
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, DEPOSITOR, shares, 0));
        sv.redeem(shares, DEPOSITOR, DEPOSITOR);
        vm.expectRevert(locked);
        sv.transfer(OWNER, 1);
        vm.expectRevert(locked);
        x.requestRedeem(shares, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();
        vm.prank(OWNER);
        uint256 dust = sv.deposit(1e6, OWNER);
        (uint256 ownerLocked,) = x.lockedShares(OWNER);
        assertEq(ownerLocked, dust);
        vm.prank(OWNER);
        sv.withdraw(1_000e6, OWNER, OWNER);

        vm.warp(block.timestamp + 300);
        _price(MANTISSA);
        vm.prank(DEPOSITOR);
        sv.redeem(shares, DEPOSITOR, DEPOSITOR);
    }
}
