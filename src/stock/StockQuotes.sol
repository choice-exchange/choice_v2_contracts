// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Currency} from "infinity-core/src/types/Currency.sol";

import {StockLib} from "./StockLib.sol";
import {IssuerQuote, Reference, StockConfig, StockContext, StockLayout, StockState} from "./StockTypes.sol";

/// @title StockQuotes
/// @notice A `StockVault`'s restocking by quotes the issuer signs, in either direction, settled
/// atomically: the `RfqSettlement` pattern pointed at the issuer. Runs by DELEGATECALL, as the vault.
///
/// - The quote is EIP-712, domain "Choice Stock Vault" / "1" / this chain / the vault, signed by the
///   vault's `quoteSigner` (an EOA, or a contract through ERC-1271). Rotating the signer voids every
///   outstanding quote; each nonce fills once; a quote expires.
/// - Its price must sit within `restockSlippageBps` of a fresh reference while the market is open for
///   the vault, no worse than that for a buy and no lower for a sale, and the reference may not be a
///   jump from the anchor.
/// - Both legs move in one transaction and are pulled from the issuer's account (`issuer`), which
///   approves the vault on both tokens. The vault pulls the issuer's leg first and checks what arrived.
/// - A buy counts against the daily restock cap and the inventory cap and spends only the vault's own
///   cash. A sale sells only booked stock. The optional path: LIMIT memo orders (`StockRestock`) are
///   the default restock, in both directions.
library StockQuotes {
    using SafeERC20 for IERC20;

    bytes32 internal constant QUOTE_TYPEHASH =
        keccak256("IssuerQuote(bool vaultBuys,uint256 stock,uint256 cash,uint256 nonce,uint64 expiry)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("Choice Stock Vault");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    error QuoteUnavailable();
    error QuoteExpired(uint64 expiry);
    error QuoteUsed(uint256 nonce);
    error BadQuoteSignature();
    error QuoteOutOfBand(uint256 cash, uint256 low, uint256 high);
    error StockDeficit();
    error InventoryCapExceeded(uint256 value, uint256 cap);
    error NotEnoughStock(uint256 wanted, uint256 booked);
    error ShortDelivery(uint256 got, uint256 wanted);

    event QuoteFilled(uint256 indexed nonce, bool vaultBuys, uint256 stock, uint256 cash, uint256 mark);

    /// @notice The EIP-712 digest the signer signs for `q`, on this vault.
    function digest(IssuerQuote memory q) internal view returns (bytes32) {
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
        bytes32 structHash = keccak256(abi.encode(QUOTE_TYPEHASH, q.vaultBuys, q.stock, q.cash, q.nonce, q.expiry));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /// @notice Fill `q`, signed `sig` by the vault's quote signer.
    function fill(StockLayout storage l, IssuerQuote calldata q, bytes calldata sig) external {
        StockConfig storage c = l.config;
        StockState storage s = l.state;
        StockContext memory ctx = l.ctx;
        address issuer = l.issuer;
        address signer = l.quoteSigner;
        if (issuer == address(0) || signer == address(0) || s.paused & StockLib.PAUSE_RESTOCK != 0) {
            revert QuoteUnavailable();
        }
        if (q.stock == 0 || q.cash == 0) revert QuoteUnavailable();
        if (block.timestamp > q.expiry) revert QuoteExpired(q.expiry);
        if (l.quoteUsed[q.nonce]) revert QuoteUsed(q.nonce);
        if (!SignatureChecker.isValidSignatureNow(signer, digest(q), sig)) revert BadQuoteSignature();
        l.quoteUsed[q.nonce] = true;

        Reference memory r = StockLib.storedReference(c, ctx);
        StockLib.requireUsable(r);
        StockLib.requireAnchored(c, s, r.price);
        if (StockLib.ownStock(s, ctx) < s.stockBooked) revert StockDeficit();
        uint256 fair = StockLib.stockToCash(ctx, q.stock, r.price, Math.Rounding.Floor);
        uint256 low = fair * (StockLib.BPS - c.restockSlippageBps) / StockLib.BPS;
        uint256 high = Math.mulDiv(fair, StockLib.BPS + c.restockSlippageBps, StockLib.BPS, Math.Rounding.Ceil);
        if (q.vaultBuys ? q.cash > high : q.cash < low) revert QuoteOutOfBand(q.cash, low, high);

        IERC20 stockToken = IERC20(Currency.unwrap(ctx.stock));
        IERC20 cashToken = IERC20(Currency.unwrap(ctx.cash));
        if (q.vaultBuys) {
            StockLib.countRestock(c, s, q.cash);
            uint256 value = StockLib.stockToCash(ctx, StockLib.stockInventory(s) + q.stock, r.price, Math.Rounding.Ceil);
            if (value > c.maxInventory) revert InventoryCapExceeded(value, c.maxInventory);
            // The reserve, an unwinding epoch's debt, the open epoch's value and the margin to hedge
            // what comes in stay.
            uint256 keepCash = StockLib.cashKeptQueued(l) + fair * 10 / c.leverageX10;
            uint256 own = StockLib.ownCash(s, ctx);
            if (own < q.cash + keepCash) revert StockLib.CashShort(q.cash + keepCash, own);
            StockLib.spendOwnCash(s, ctx, q.cash);
            uint256 got = _pull(stockToken, issuer, q.stock);
            cashToken.safeTransfer(issuer, q.cash);
            s.stockBooked += got;
            s.cashBooked -= q.cash;
        } else {
            if (q.stock > s.stockBooked) revert NotEnoughStock(q.stock, s.stockBooked);
            StockLib.ensureToken(ctx, ctx.stock, q.stock);
            s.cashBooked += _pull(cashToken, issuer, q.cash);
            stockToken.safeTransfer(issuer, q.stock);
            s.stockBooked -= q.stock;
        }
        emit QuoteFilled(q.nonce, q.vaultBuys, q.stock, q.cash, r.price);
    }

    /// @dev Pull `amount` from `from` and return what arrived, which must be all of it.
    function _pull(IERC20 token, address from, uint256 amount) private returns (uint256 got) {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        got = token.balanceOf(address(this)) - before;
        if (got < amount) revert ShortDelivery(got, amount);
    }
}
