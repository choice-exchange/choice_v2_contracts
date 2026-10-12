// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IExchangeDerivatives} from "../src/interfaces/IExchangeDerivatives.sol";
import {StockLib} from "../src/stock/StockLib.sol";
import {StockVault} from "../src/stock/StockVault.sol";
import {Refusal, StockConfig, StockState} from "../src/stock/StockTypes.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// Maker hedging on the stock vault harness: 30 STOCK held unhedged at 300, a hedge band of 10 and
/// a 60 bps price band, so a maker order may rest anywhere from 298.20 to 301.80.
contract StockMakerTest is StockVaultHarness {
    uint32 internal constant TIMEOUT = 600;

    function setUp() public override {
        super.setUp();
        StockConfig memory c = _cfg();
        c.makerTimeout = TIMEOUT;
        _setCfg(c);
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _place(uint256 price) internal returns (string memory) {
        vm.prank(KEEPER);
        assertTrue(sv.placeMaker(price));
        return x.state().makerHash;
    }

    function _resting(string memory hash)
        internal
        view
        returns (IExchangeDerivatives.TrimmedDerivativeLimitOrder[] memory)
    {
        string[] memory hashes = new string[](1);
        hashes[0] = hash;
        return exchange.derivativeOrdersByHashes(
            IExchangeDerivatives.DerivativeOrdersRequest({marketID: MARKET, subaccountID: _sub(), orderHashes: hashes})
        );
    }

    // ── placing ───────────────────────────────────────────────────────────

    function test_aMakerOrderRestsForTheGapAndValueIsUnchanged() public {
        uint256 nav = sv.totalAssets();
        string memory hash = _place(300.5e18);
        StockState memory s = x.state();
        assertTrue(s.makerSell);
        assertEq(s.makerFillable, 30 ether);
        assertEq(s.makerPlacedAt, block.timestamp);
        IExchangeDerivatives.TrimmedDerivativeLimitOrder[] memory o = _resting(hash);
        assertEq(o.length, 1);
        assertEq(o[0].price, 300.5e18);
        assertEq(o[0].quantity, 30 ether);
        assertEq(o[0].margin, 30 * 300.5e18 / 3, "margin at 3x");
        assertEq(sv.totalAssets(), nav, "the held margin is still the vault's");
    }

    function test_aMakerFillIsReadBackAndTheRestStillCounts() public {
        uint256 nav = sv.totalAssets();
        string memory hash = _place(300.5e18);
        exchange.fillResting(hash, 10 ether);
        x.confirmHedge();
        StockState memory s = x.state();
        assertEq(s.shortConfirmed, 10 ether);
        assertEq(s.makerFillable, 20 ether);
        // Sold 10 at 300.50 against a mark of 300: 5 of PnL, give or take a unit of rounding.
        assertApproxEqAbs(sv.totalAssets(), nav + 5e6, 2);
    }

    function test_aFullyFilledMakerOrderClears() public {
        string memory hash = _place(300.5e18);
        exchange.fillResting(hash, 30 ether);
        x.confirmHedge();
        StockState memory s = x.state();
        assertEq(s.shortConfirmed, 30 ether);
        assertEq(bytes(s.makerHash).length, 0);
        assertEq(s.makerFillable, 0);
    }

    function test_matchingCanDropTheOrderUnfilled() public {
        uint256 nav = sv.totalAssets();
        string memory hash = _place(300.5e18);
        exchange.matchCancel(hash);
        x.confirmHedge();
        StockState memory s = x.state();
        assertEq(s.shortConfirmed, 0, "gone is not filled");
        assertEq(bytes(s.makerHash).length, 0);
        assertEq(sv.totalAssets(), nav);
    }

    function test_replacingCancelsTheRestingOrderFirst() public {
        string memory first = _place(300.5e18);
        string memory second = _place(300.2e18);
        assertEq(exchange.cancels(), 1);
        assertEq(_resting(first).length, 0);
        assertEq(_resting(second).length, 1);
        assertTrue(keccak256(bytes(first)) != keccak256(bytes(second)));
    }

    function test_aBuyMakerOnlyReducesTheShort() public {
        _hedge(300e18); // short 30
        _swap(true, false, 10 ether); // the vault sells 10: 20 held against a short of 30
        _price(MANTISSA);
        string memory hash = _place(299.5e18);
        StockState memory s = x.state();
        assertFalse(s.makerSell);
        assertEq(s.makerFillable, 10 ether);
        assertEq(_resting(hash)[0].margin, 0, "reduce-only");
        exchange.fillResting(hash, 10 ether);
        x.confirmHedge();
        assertEq(x.state().shortConfirmed, 20 ether);
    }

    function test_insideTheBandNothingIsPlaced() public {
        _hedge(300e18);
        vm.prank(KEEPER);
        assertFalse(sv.placeMaker(300.5e18));
        assertEq(exchange.limitOrdersPlaced(), 0);
    }

    // ── refusals ──────────────────────────────────────────────────────────

    function test_aMakerPriceOutsideTheBandOrOffTheTickIsRefused() public {
        uint256[3] memory bad = [uint256(301.81e18), 298.19e18, 300.001e18];
        for (uint256 k; k < 3; ++k) {
            vm.prank(KEEPER);
            vm.expectRevert(abi.encodeWithSelector(StockLib.MakerPriceOutOfBand.selector, bad[k], 298.2e18, 301.8e18));
            sv.placeMaker(bad[k]);
        }
    }

    function test_aMakerOrderThatWouldCrossReverts() public {
        exchange.setBook(300.6e18, 300.7e18);
        vm.prank(KEEPER);
        vm.expectRevert(bytes("exceeds top of book"));
        sv.placeMaker(300.5e18);
    }

    function test_onlyTheKeeperPlaces() public {
        vm.prank(TRADER);
        vm.expectRevert(StockVault.NotKeeper.selector);
        sv.placeMaker(300.5e18);
    }

    function test_makerHedgingCanBeOff() public {
        _setCfg(_cfg()); // makerTimeout 0
        vm.prank(KEEPER);
        vm.expectRevert(StockLib.MakerOff.selector);
        sv.placeMaker(300.5e18);
    }

    function test_theMakerTimeoutIsBounded() public {
        StockConfig memory c = _cfg();
        c.makerTimeout = 1 days + 1;
        vm.prank(OWNER);
        vm.expectRevert(StockLib.BadConfig.selector);
        x.setConfig(c);
    }

    // ── cancelling and replacing ──────────────────────────────────────────

    function test_anyoneCancelsOnlyAfterTheTimeout() public {
        _place(300.5e18);
        vm.prank(TRADER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.MakerResting.selector, T_REGULAR + TIMEOUT));
        sv.cancelMaker();
        vm.warp(T_REGULAR + TIMEOUT);
        vm.prank(TRADER);
        sv.cancelMaker();
        assertEq(bytes(x.state().makerHash).length, 0);
        vm.expectRevert(StockLib.NoMaker.selector);
        sv.cancelMaker();
    }

    function test_aMarketHedgeCancelsTheMakerOrderFirst() public {
        _place(300.5e18);
        vm.prank(KEEPER);
        assertTrue(x.syncHedge());
        assertEq(exchange.cancels(), 1);
        assertEq(bytes(x.state().makerHash).length, 0);
        assertEq(x.state().pendingQty, 30 ether);
    }

    function test_thePublicCannotReplaceAFreshMakerOrder() public {
        _place(300.5e18);
        vm.warp(T_REGULAR + 300); // past publicHedgeDelay, not the maker timeout
        _price(MANTISSA);
        vm.prank(TRADER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.MakerResting.selector, T_REGULAR + TIMEOUT));
        x.syncHedge();
        vm.warp(T_REGULAR + TIMEOUT);
        _price(MANTISSA);
        vm.prank(TRADER);
        assertTrue(x.syncHedge());
        assertEq(exchange.cancels(), 1);
    }

    // ── exposure ──────────────────────────────────────────────────────────

    function test_exposureCountsWhatTheRestingOrderMayStillFill() public {
        StockConfig memory c = _cfg();
        c.makerTimeout = TIMEOUT;
        c.maxUnhedged = 200e6;
        _setCfg(c);
        _place(300.5e18);
        // If the order fills, selling one more STOCK leaves the vault short one it does not hold.
        _expectRefusal(Refusal.Unhedged);
        _swap(true, false, 1 ether);
        vm.prank(KEEPER);
        sv.cancelMaker();
        _swap(true, false, 1 ether);
        assertEq(x.state().stockBooked, 29 ether);
    }
}
