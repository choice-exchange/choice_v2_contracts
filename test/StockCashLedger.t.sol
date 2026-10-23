// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IExchangeDerivatives} from "../src/interfaces/IExchangeDerivatives.sol";
import {SubaccountLib} from "../src/libraries/SubaccountLib.sol";
import {Refusal, StockConfig} from "../src/stock/StockTypes.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// The cash ledger and the hedge subaccount: the short trades from a subaccount of its own, so the
/// vault's bank cash moves only on its own calls, booked as it moves, and anything else that arrives
/// is out of the value until it is booked. Cash the vault takes in goes straight into Choice vault
/// claims, which fills pay out of.
contract StockCashLedgerTest is StockVaultHarness {
    /// The margin the harness's first hedge posts: 30 STOCK short at 3x (3,000), plus the loss a sell
    /// at its worst price (10 bps under the mark: a market hedge crosses at most `minSpread`) would open at (9).
    uint256 internal constant MARGIN = 3_009e6;

    function _bank() internal view returns (uint256) {
        return cash.balanceOf(address(sv)) + _claims(cash);
    }

    function _subCash() internal view returns (uint256 available, uint256 total) {
        return exchange.subaccountDeposit(_sub(), CASH_DENOM);
    }

    function test_theShortTradesFromItsOwnSubaccount() public {
        uint256 bank = _bank();
        uint256 nav = sv.totalAssets();
        _hedge(PRICE);
        assertEq(exchange.subaccountPositions(_sub()).length, 1);
        assertEq(
            exchange.subaccountPositions(SubaccountLib.defaultSubaccount(address(sv))).length,
            0,
            "nothing on the default subaccount"
        );
        (uint256 available, uint256 total) = _subCash();
        // One unit stays: the vault never withdraws the last unit the exchange reports (it rounds).
        assertEq(total, 1, "the margin went into the position");
        assertEq(available, 1, "the confirmation brought the fee hold back");
        assertEq(_bank(), bank - MARGIN - 1);
        assertEq(x.state().cashBooked, _bank(), "booked as it left");
        assertEq(sv.totalAssets(), nav - 1, "less the unit the subaccount keeps, which never comes back");
    }

    function test_whatTheShortPaysBackLandsInItsSubaccountAndComesBackBooked() public {
        _hedge(PRICE);
        uint256 bank = _bank();
        uint256 nav = sv.totalAssets();
        exchange.forceSettle(_sub(), MARKET, PRICE, address(sv)); // closed at its entry: the margin back
        assertEq(_bank(), bank, "the bank does not move");
        (uint256 available,) = _subCash();
        assertEq(available, MARGIN + 1, "plus the unit the hedge left");
        assertEq(sv.totalAssets(), nav, "the subaccount's cash is in the value");
        x.confirmHedge();
        assertEq(_bank(), bank + MARGIN);
        assertEq(x.state().cashBooked, _bank());
        assertEq(sv.totalAssets(), nav);
    }

    function test_aRestingMakersHoldIsFundedValuedAndReturned() public {
        StockConfig memory c = _cfg();
        c.makerTimeout = 600;
        _setCfg(c);
        uint256 bank = _bank();
        uint256 nav = sv.totalAssets();
        exchange.setBook(299e18, 301e18);
        vm.prank(KEEPER);
        assertTrue(x.placeMaker(301e18));
        (uint256 available, uint256 total) = _subCash();
        assertEq(total - available, 3_010e6, "the hold: 30 at 301, at 3x");
        assertEq(_bank() + total, bank, "the hold and its fee buffer sit in the subaccount");
        assertEq(sv.totalAssets(), nav - 1, "and in the value, but for the unit the subaccount keeps");
        vm.roll(block.number + 1);
        vm.prank(KEEPER);
        x.cancelMaker();
        (, total) = _subCash();
        assertEq(total, 1, "all but the unit a withdrawal leaves");
        assertEq(_bank(), bank - 1, "cancelled: back in the bank, booked");
        assertEq(x.state().cashBooked, bank - 1);
        assertEq(cash.balanceOf(address(sv)), 0, "and into claims");
    }

    function test_aDonationIsOutOfTheValueUntilBooked() public {
        uint256 nav = sv.totalAssets();
        uint256 free = sv.maxWithdraw(OWNER);
        cash.mint(address(sv), 1_000e6);
        assertEq(sv.totalAssets(), nav);
        assertEq(sv.maxWithdraw(OWNER), free, "nor spendable");
        x.syncWindfall();
        assertEq(sv.totalAssets(), nav + 1_000e6);
        assertEq(cash.balanceOf(address(sv)), 0, "booked, and into claims");
    }

    /// Mainnet 10-20: deposits stayed plain cash, and fills pay out of claims only, so the vault quoted
    /// buys but refused every sell (reason 10, `Inventory`) until the keeper moved the cash by hand. A
    /// deposit now lands in claims, and a sell fills with no keeper call in between.
    function test_aDepositLandsInClaimsSoASellFillsAtOnce() public {
        uint256 claimed = _claims(cash);
        vm.prank(KEEPER);
        x.fromClaims(true, claimed); // the rehearsal vault's state: all of its cash plain
        _expectRefusal(Refusal.Inventory);
        _swap(false, true, 3 ether); // a taker sells the vault 3 STOCK
        uint256 nav = sv.totalAssets();

        cash.mint(DEPOSITOR, 1_000e6);
        vm.startPrank(DEPOSITOR);
        cash.approve(address(sv), 1_000e6);
        sv.deposit(1_000e6, DEPOSITOR);
        vm.stopPrank();
        assertEq(cash.balanceOf(address(sv)), 0, "every unit of cash went into claims");
        assertEq(_claims(cash), 11_000e6);
        assertEq(sv.totalAssets(), nav + 1_000e6, "which changes nothing the vault is worth");

        uint256 before = cash.balanceOf(TRADER);
        _swap(false, true, 3 ether);
        assertEq(cash.balanceOf(TRADER) - before, 3 * _bid(25) / 1e12, "filled, out of claims");
        assertEq(x.state().stockBooked, 33 ether);
    }

    /// The margin a cover frees comes back at the confirmation into claims, ready for the next sell.
    function test_aCoversMarginComesBackIntoClaims() public {
        uint256 n = block.number; // via-IR reads `block.number` once per function: roll by explicit numbers
        _hedge(PRICE); // short 30
        assertEq(cash.balanceOf(address(sv)), 0, "the fee hold the confirmation brought back is in claims");
        vm.roll(n + 2);
        _swap(true, false, 10 ether); // a taker buys 10: the short is 10 over
        vm.prank(KEEPER);
        assertTrue(x.syncHedge()); // cover 10, reduce-only
        vm.roll(n + 3);
        exchange.endBlock(PRICE); // a third of the margin back to the subaccount
        (uint256 back,) = _subCash();
        assertGt(back, 1_000e6);
        uint256 claims = _claims(cash);
        x.confirmHedge();
        assertEq(cash.balanceOf(address(sv)), 0, "nothing left plain");
        assertEq(_claims(cash), claims + back - 1, "all of it but the unit the subaccount keeps");
    }

    function test_cashThatLeftUnbookedStopsCountingNoMore() public {
        // Should cash ever leave without the vault sending it, the value follows what is held.
        vm.prank(KEEPER);
        x.fromClaims(true, 1_000e6);
        uint256 nav = sv.totalAssets();
        uint256 bank = cash.balanceOf(address(sv));
        vm.prank(address(sv));
        cash.transfer(address(0xdead), bank);
        assertEq(sv.totalAssets(), nav - bank);
    }

    function test_theDenomIsFixedAtConstruction() public view {
        assertEq(x.state().cashDenom, CASH_DENOM);
    }

    function _position() internal view returns (IExchangeDerivatives.DerivativePosition memory) {
        return exchange.subaccountPositions(_sub())[0];
    }
}
