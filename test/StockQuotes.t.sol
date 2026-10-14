// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StockLib} from "../src/stock/StockLib.sol";
import {StockModule} from "../src/stock/StockModule.sol";
import {StockQuotes} from "../src/stock/StockQuotes.sol";
import {IssuerQuote, Refusal, StockConfig} from "../src/stock/StockTypes.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// A contract signer that approves exactly the digests it is told to.
contract Mock1271 {
    mapping(bytes32 digest => bool) public approved;

    function approve(bytes32 digest) external {
        approved[digest] = true;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return approved[digest] ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// Issuer quotes on the stock vault harness: 30 STOCK booked at 300, a 300 bps band, a 10,000 daily
/// restock cap. The issuer's account holds both tokens and approves the vault on both.
contract StockQuotesTest is StockVaultHarness {
    uint256 internal constant QUOTE_KEY = 0x9007;
    uint64 internal quoteNonce;

    function setUp() public override {
        super.setUp();
        vm.prank(OWNER);
        x.setQuoteSigner(vm.addr(QUOTE_KEY));
        cash.mint(ISSUER, 1_000_000e6);
        stock.mint(ISSUER, 1_000 ether);
        vm.startPrank(ISSUER);
        cash.approve(address(sv), type(uint256).max);
        stock.approve(address(sv), type(uint256).max);
        vm.stopPrank();
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _quote(bool vaultBuys, uint256 stockAmount, uint256 cashAmount) internal returns (IssuerQuote memory) {
        return IssuerQuote({
            vaultBuys: vaultBuys,
            stock: stockAmount,
            cash: cashAmount,
            nonce: ++quoteNonce,
            expiry: uint64(block.timestamp + 60)
        });
    }

    function _sign(uint256 key, IssuerQuote memory q) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, x.quoteDigest(q));
        return abi.encodePacked(r, s, v);
    }

    function _fill(IssuerQuote memory q, bytes memory sig) internal {
        vm.prank(KEEPER);
        x.fillQuote(q, sig);
    }

    // ── fills ─────────────────────────────────────────────────────────────

    function test_theVaultBuysAtAQuoteWithinTheBand() public {
        IssuerQuote memory q = _quote(true, 5 ether, 1_510e6);
        uint256 issuerCash = cash.balanceOf(ISSUER);
        _fill(q, _sign(QUOTE_KEY, q));
        assertEq(x.state().stockBooked, 35 ether);
        assertEq(cash.balanceOf(ISSUER) - issuerCash, 1_510e6);
        assertEq(stock.balanceOf(ISSUER), 995 ether);
        assertEq(x.state().restockUsed, 1_510e6, "counts against the daily cap");
    }

    function test_theVaultSellsAtAQuoteWithinTheBand() public {
        IssuerQuote memory q = _quote(false, 5 ether, 1_490e6);
        uint256 issuerCash = cash.balanceOf(ISSUER);
        _fill(q, _sign(QUOTE_KEY, q));
        assertEq(x.state().stockBooked, 25 ether);
        assertEq(issuerCash - cash.balanceOf(ISSUER), 1_490e6);
        assertEq(stock.balanceOf(ISSUER), 1_005 ether);
        assertEq(x.state().restockUsed, 0, "sales do not count");
    }

    function test_aQuoteOutsideTheBandIsRefused() public {
        uint256 low = 1_500e6 * 9_700 / 10_000;
        uint256 high = Math.mulDiv(1_500e6, 10_300, 10_000, Math.Rounding.Ceil);
        IssuerQuote memory buy = _quote(true, 5 ether, high + 1);
        bytes memory sig = _sign(QUOTE_KEY, buy);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockQuotes.QuoteOutOfBand.selector, high + 1, low, high));
        x.fillQuote(buy, sig);
        IssuerQuote memory sell = _quote(false, 5 ether, low - 1);
        sig = _sign(QUOTE_KEY, sell);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockQuotes.QuoteOutOfBand.selector, low - 1, low, high));
        x.fillQuote(sell, sig);
    }

    // ── the signature ─────────────────────────────────────────────────────

    function test_eachQuoteFillsOnceBeforeItsExpiry() public {
        IssuerQuote memory q = _quote(true, 1 ether, 300e6);
        bytes memory sig = _sign(QUOTE_KEY, q);
        _fill(q, sig);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockQuotes.QuoteUsed.selector, q.nonce));
        x.fillQuote(q, sig);

        IssuerQuote memory late = _quote(true, 1 ether, 300e6);
        sig = _sign(QUOTE_KEY, late);
        vm.warp(late.expiry + 1);
        _price(MANTISSA);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockQuotes.QuoteExpired.selector, late.expiry));
        x.fillQuote(late, sig);
    }

    function test_onlyTheQuoteSignerCountsAndRotationVoidsQuotes() public {
        IssuerQuote memory q = _quote(true, 1 ether, 300e6);
        bytes memory forged = _sign(0xBAD, q);
        vm.prank(KEEPER);
        vm.expectRevert(StockQuotes.BadQuoteSignature.selector);
        x.fillQuote(q, forged);

        bytes memory sig = _sign(QUOTE_KEY, q);
        vm.prank(OWNER);
        x.setQuoteSigner(vm.addr(0x5EC0));
        vm.prank(KEEPER);
        vm.expectRevert(StockQuotes.BadQuoteSignature.selector);
        x.fillQuote(q, sig);
    }

    function test_aContractSignerThroughErc1271() public {
        Mock1271 wallet = new Mock1271();
        vm.prank(OWNER);
        x.setQuoteSigner(address(wallet));
        IssuerQuote memory q = _quote(true, 1 ether, 300e6);
        vm.prank(KEEPER);
        vm.expectRevert(StockQuotes.BadQuoteSignature.selector);
        x.fillQuote(q, "");
        wallet.approve(x.quoteDigest(q));
        _fill(q, "");
        assertEq(x.state().stockBooked, 31 ether);
    }

    function test_theDigestIsEip712OnThisVault() public view {
        // forge-lint: disable-next-line(unsafe-typecast) - a 2026 timestamp.
        uint64 expiry = uint64(T_REGULAR + 60);
        IssuerQuote memory q = IssuerQuote({vaultBuys: true, stock: 2 ether, cash: 600e6, nonce: 7, expiry: expiry});
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Choice Stock Vault"),
                keccak256("1"),
                block.chainid,
                address(sv)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("IssuerQuote(bool vaultBuys,uint256 stock,uint256 cash,uint256 nonce,uint64 expiry)"),
                q.vaultBuys,
                q.stock,
                q.cash,
                q.nonce,
                q.expiry
            )
        );
        assertEq(x.quoteDigest(q), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    // ── guards ────────────────────────────────────────────────────────────

    function test_aBuyIsHeldToTheDailyCapAndTheInventoryCap() public {
        IssuerQuote memory big = _quote(true, 34 ether, 10_200e6);
        bytes memory sig = _sign(QUOTE_KEY, big);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.RestockCapExceeded.selector, 10_200e6, 10_000e6));
        x.fillQuote(big, sig);

        StockConfig memory c = _cfg();
        c.maxInventory = 10_000e6; // 9,000 held
        _setCfg(c);
        IssuerQuote memory over = _quote(true, 4 ether, 1_200e6);
        sig = _sign(QUOTE_KEY, over);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockQuotes.InventoryCapExceeded.selector, 10_200e6, 10_000e6));
        x.fillQuote(over, sig);
    }

    function test_aSaleSellsOnlyBookedStock() public {
        IssuerQuote memory q = _quote(false, 31 ether, 9_300e6);
        bytes memory sig = _sign(QUOTE_KEY, q);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockQuotes.NotEnoughStock.selector, 31 ether, 30 ether));
        x.fillQuote(q, sig);
    }

    function test_aBuySpendsOnlyTheVaultsOwnCash() public {
        // Withdraw all but 100 of the vault's cash: a 300 buy cannot come out of anyone else's.
        uint256 free = sv.maxWithdraw(OWNER) - 100e6;
        vm.prank(OWNER);
        sv.withdraw(free, OWNER, OWNER);
        IssuerQuote memory q = _quote(true, 1 ether, 300e6);
        bytes memory sig = _sign(QUOTE_KEY, q);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.CashShort.selector, 300e6, 100e6));
        x.fillQuote(q, sig);
    }

    function test_quotesNeedTheKeeperAFreshPriceAndRestockUnpaused() public {
        IssuerQuote memory q = _quote(true, 1 ether, 300e6);
        bytes memory sig = _sign(QUOTE_KEY, q);
        vm.prank(TRADER);
        vm.expectRevert(StockModule.NotKeeper.selector);
        x.fillQuote(q, sig);

        vm.warp(block.timestamp + 10);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Stale));
        x.fillQuote(q, sig);

        _price(MANTISSA);
        vm.prank(GUARDIAN);
        x.pause(StockLib.PAUSE_RESTOCK);
        vm.prank(KEEPER);
        vm.expectRevert(StockQuotes.QuoteUnavailable.selector);
        x.fillQuote(q, sig);
    }
}
