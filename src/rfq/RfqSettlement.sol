// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title RfqSettlement
/// @notice Settles firm quotes from ONE off-chain market maker (an issuer, a desk) against
/// inventory this contract holds, in a single transaction.
///
/// **Why it exists.** An issuer that fills orders by hand - a customer sends payment, the issuer
/// mints or pays out later at whatever the price is by then - cannot be composed with anything
/// on chain. Nothing can call it, nothing can quote against it, and a counterparty carries price
/// risk for as long as the fill takes. This contract moves the issuer's role off the hot path:
/// the issuer's quote server SIGNS a price, and anyone holding that signature settles it here,
/// atomically, against inventory the issuer parked in advance. Minting and redemption against
/// the underlying stay with the issuer and happen in the background to refill the inventory.
///
/// **What the issuer keeps control of.**
/// - Price, size and expiry: every quote is an EIP-712 message from `signer`, and a quote is
///   honoured exactly as signed or not at all. There are no partial fills.
/// - Who may fill: a quote names its `taker`, or `address(0)` for anyone holding it.
/// - Blast radius: each token this contract pays out has an outflow cap per rolling window. A
///   token with no cap cannot be paid out at all, so a leaked signing key can lose at most one
///   window's cap per token - never the whole inventory.
/// - Cancellation: `invalidateNonces` cancels individual quotes; `setSigner` voids every
///   outstanding quote at once, because signatures are checked against the CURRENT signer.
/// - Pause: the signer or the owner can stop all fills; only the owner can resume.
///
/// `signer` may be an EOA or an ERC-1271 contract (a Safe, a smart account).
///
/// Inventory is deposited by plain transfer and leaves only through `fill` or `withdraw`.
contract RfqSettlement is Ownable2Step, ReentrancyGuardTransient, EIP712 {
    using SafeERC20 for IERC20;

    /// @param taker who may fill; `address(0)` lets anyone holding the signature fill it
    /// @param tokenIn what the taker pays this contract, exactly `amountIn`
    /// @param tokenOut what this contract pays the taker's recipient, exactly `amountOut`
    /// @param nonce single-use; unordered, so a quote server can hand out many at once
    /// @param deadline unix seconds, inclusive
    struct Quote {
        address taker;
        address tokenIn;
        uint256 amountIn;
        address tokenOut;
        uint256 amountOut;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice Per-token payout budget. `cap` per `WINDOW`, reset lazily on the first fill
    /// after the window elapses.
    struct Outflow {
        uint96 cap;
        uint96 used;
        uint64 windowStart;
    }

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(address taker,address tokenIn,uint256 amountIn,address tokenOut,uint256 amountOut,uint256 nonce,uint256 deadline)"
    );

    uint256 public constant WINDOW = 1 days;

    address public signer;
    bool public paused;

    /// @notice Used and cancelled nonces, 256 per word: bit `nonce & 0xff` of word `nonce >> 8`.
    mapping(uint256 wordPos => uint256 bits) public nonceBitmap;

    mapping(address token => Outflow) public outflow;

    event QuoteFilled(
        bytes32 indexed digest,
        address indexed taker,
        address indexed recipient,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut,
        uint256 nonce
    );
    event SignerSet(address indexed signer);
    event PausedSet(bool paused);
    event OutflowCapSet(address indexed token, uint256 cap);
    event NoncesInvalidated(uint256 indexed wordPos, uint256 mask);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error IsPaused();
    error Expired();
    error WrongTaker();
    error SameToken();
    error ZeroRecipient();
    error BadSignature();
    error NonceUsed(uint256 nonce);
    error OutflowCapExceeded(address token, uint256 wanted, uint256 remaining);
    error ShortPayment(uint256 received, uint256 expected);
    error CapTooLarge();
    error NotSignerOrOwner();

    constructor(address owner_, address signer_) Ownable(owner_) EIP712("RfqSettlement", "1") {
        signer = signer_;
        emit SignerSet(signer_);
    }

    // ── settlement ────────────────────────────────────────────────────────

    /// @notice Pay `q.amountIn` of `q.tokenIn` and receive `q.amountOut` of `q.tokenOut` at
    /// `recipient`, exactly as `signer` signed it.
    /// @dev The caller must have approved this contract for `q.amountIn` of `q.tokenIn`.
    function fill(Quote calldata q, bytes calldata signature, address recipient) external nonReentrant {
        if (paused) revert IsPaused();
        if (block.timestamp > q.deadline) revert Expired();
        if (q.taker != address(0) && q.taker != msg.sender) revert WrongTaker();
        if (q.tokenIn == q.tokenOut) revert SameToken();
        if (recipient == address(0)) revert ZeroRecipient();

        bytes32 digest = quoteDigest(q);
        if (!SignatureChecker.isValidSignatureNow(signer, digest, signature)) revert BadSignature();

        _useNonce(q.nonce);
        _spendOutflow(q.tokenOut, q.amountOut);

        // Measured, not assumed: a token that skims on transfer would otherwise underpay the
        // inventory on every fill while the payout side stays exact.
        IERC20 tokenIn = IERC20(q.tokenIn);
        uint256 before = tokenIn.balanceOf(address(this));
        tokenIn.safeTransferFrom(msg.sender, address(this), q.amountIn);
        uint256 received = tokenIn.balanceOf(address(this)) - before;
        if (received < q.amountIn) revert ShortPayment(received, q.amountIn);

        IERC20(q.tokenOut).safeTransfer(recipient, q.amountOut);

        emit QuoteFilled(digest, msg.sender, recipient, q.tokenIn, q.amountIn, q.tokenOut, q.amountOut, q.nonce);
    }

    // ── views ─────────────────────────────────────────────────────────────

    /// @notice The EIP-712 digest `signer` signs for `q`. A quote server can check its own
    /// signatures against this with an `eth_call` before handing them out.
    function quoteDigest(Quote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(QUOTE_TYPEHASH, q)));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function isNonceUsed(uint256 nonce) external view returns (bool) {
        return nonceBitmap[nonce >> 8] & (1 << (nonce & 0xff)) != 0;
    }

    /// @notice What `token` can still pay out in the current window.
    function remainingOutflow(address token) external view returns (uint256) {
        Outflow memory o = outflow[token];
        if (block.timestamp >= uint256(o.windowStart) + WINDOW) return o.cap;
        return o.used >= o.cap ? 0 : o.cap - o.used;
    }

    // ── issuer controls ───────────────────────────────────────────────────

    /// @notice Cancel quotes: every set bit of `mask` marks one nonce in word `wordPos` used.
    /// The signer can do this as well as the owner, so a quote server can withdraw quotes it
    /// handed out without holding the owner key.
    function invalidateNonces(uint256 wordPos, uint256 mask) external {
        if (msg.sender != signer && msg.sender != owner()) revert NotSignerOrOwner();
        nonceBitmap[wordPos] |= mask;
        emit NoncesInvalidated(wordPos, mask);
    }

    /// @notice Stop (or resume) every fill. Either key can stop; only the owner can resume, so a
    /// compromised signer cannot undo the owner's response to it.
    function setPaused(bool paused_) external {
        if (paused_) {
            if (msg.sender != signer && msg.sender != owner()) revert NotSignerOrOwner();
        } else {
            _checkOwner();
        }
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Rotate the quote key. Every quote signed by the previous key stops verifying.
    function setSigner(address signer_) external onlyOwner {
        signer = signer_;
        emit SignerSet(signer_);
    }

    /// @notice Set `token`'s payout cap per `WINDOW`. Zero disables paying it out. The current
    /// window's usage carries over, so lowering a cap mid-window takes effect immediately.
    function setOutflowCap(address token, uint256 cap) external onlyOwner {
        if (cap > type(uint96).max) revert CapTooLarge();
        // forge-lint: disable-next-line(unsafe-typecast) - bounded above.
        outflow[token].cap = uint96(cap);
        emit OutflowCapSet(token, cap);
    }

    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    // ── internals ─────────────────────────────────────────────────────────

    function _useNonce(uint256 nonce) private {
        uint256 bit = 1 << (nonce & 0xff);
        uint256 word = nonceBitmap[nonce >> 8];
        if (word & bit != 0) revert NonceUsed(nonce);
        nonceBitmap[nonce >> 8] = word | bit;
    }

    function _spendOutflow(address token, uint256 amount) private {
        Outflow memory o = outflow[token];
        if (block.timestamp >= uint256(o.windowStart) + WINDOW) {
            o.windowStart = uint64(block.timestamp);
            o.used = 0;
        }
        uint256 remaining = o.used >= o.cap ? 0 : o.cap - o.used;
        if (amount > remaining) revert OutflowCapExceeded(token, amount, remaining);
        // forge-lint: disable-next-line(unsafe-typecast) - amount <= remaining <= cap <= uint96.
        o.used += uint96(amount);
        outflow[token] = o;
    }
}
