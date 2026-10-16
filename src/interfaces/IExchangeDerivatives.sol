// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @notice The `0x65` exchange-precompile methods a contract needs to hold a perpetual position
/// for itself.
/// @dev Signatures taken from injective-core's abigen bindings
/// (`injective-chain/modules/evm/precompiles/bindings/cosmos/precompile/exchange`):
/// `createDerivativeMarketOrder` `0xb84857a1`, `subaccountPositions` `0x9bb15b3c`,
/// `increasePositionMargin` `0x8ff96af4`, `createDerivativeLimitOrder` `0x20c69837`,
/// `cancelDerivativeOrder` `0x44b9bf3a`, `derivativeOrdersByHashes` `0xd6673c03`. Kept apart from `IExchangeModule`, which the burn leg
/// uses and which stays exactly the two methods it needs.
///
/// **What a caller must know:**
/// - `sender` is the caller's own address. Trading for oneself needs no authz grant; trading for
///   another account needs one.
/// - Order `price`, `quantity` and `margin`, and every field `subaccountPositions` returns, are in
///   the 18-decimal API format: the human value times 1e18 (a price of 312.5 USDC is
///   `312.5e18`). Margin amounts on `increasePositionMargin` are the same format.
/// - A market order is NOT executed in the transaction that places it. It is queued and matched
///   in the block's EndBlocker; the response carries only `orderHash` and `cid`, every quantity
///   in it is zero. Read the resulting position in a later block.
/// - `price` on a market order is the WORST price accepted, and the order REVERTS at placement unless
///   it crosses the best opposite price then (an empty side reverts too). One that stops crossing
///   before the EndBlocker is dropped there, and its hold is released. One market order per
///   subaccount, market and block; and none while the exchange is in post-only mode.
/// - The minimum notional is checked at the order price (the worst price, for a market order), for
///   every order, reduce-only included. Off-tick prices and quantities revert; nothing is rounded.
/// - `margin` zero makes an order reduce-only. The exchange cuts a reduce-only order to what the
///   position (less the subaccount's other closing orders) leaves to reduce.
/// - An order holds its margin plus price times quantity times the fee. The fee is paid at the fill
///   price; a sell filled above its worst price pays the extra fee out of its margin. 40% of every fee
///   goes to the relayer: an empty `feeRecipient` makes that the sender, credited to its DEFAULT
///   subaccount (whole units swept to the bank, the fraction left there).
/// - Every write either returns true or reverts; none returns false.
/// - The default subaccount (nonce 0) trades straight off the account's bank balance: no deposit,
///   and every credit to it is swept back to bank.
/// - Only `buy`, `sell`, `buyPostOnly` and `sellPostOnly` order types exist here; atomic orders
///   cannot be sent through this precompile.
/// - A POST-ONLY limit order is checked against the resting book when placed and reverts if it
///   would cross; otherwise it rests at once, in the placing transaction, and
///   `derivativeOrdersByHashes` sees it there. Its margin hold (margin plus price times quantity
///   times the maker fee, if positive) leaves the bank balance at placement and the unfilled part
///   comes back on cancel. A plain limit order waits in a transient store until the EndBlocker
///   and is not visible until then. Limit orders never expire.
/// - A resting order fills mostly in the EndBlocker; a fill lowers only its `fillable`. Matching
///   can also CANCEL a resting order (failed margin check, open-notional cap), so an order missing
///   from `derivativeOrdersByHashes` is not necessarily a filled one: read the position.
interface IExchangeDerivatives {
    struct DerivativeOrder {
        string marketID;
        string subaccountID;
        string feeRecipient;
        uint256 price;
        uint256 quantity;
        string cid;
        string orderType;
        uint256 margin;
        uint256 triggerPrice;
    }

    struct CreateDerivativeMarketOrderResponse {
        string orderHash;
        string cid;
        uint256 quantity;
        uint256 price;
        uint256 fee;
        uint256 payout;
        uint256 deltaExecutionQuantity;
        uint256 deltaExecutionMargin;
        uint256 deltaExecutionPrice;
        bool deltaIsLong;
    }

    struct CreateDerivativeLimitOrderResponse {
        string orderHash;
        string cid;
    }

    /// @param subaccountID the full 32-byte hex id; the nonce shorthand matches nothing
    struct DerivativeOrdersRequest {
        string marketID;
        string subaccountID;
        string[] orderHashes;
    }

    struct TrimmedDerivativeLimitOrder {
        uint256 price;
        uint256 quantity;
        uint256 margin;
        uint256 fillable;
        bool isBuy;
        string orderHash;
        string cid;
    }

    struct DerivativePosition {
        string subaccountID;
        string marketID;
        bool isLong;
        uint256 quantity;
        uint256 entryPrice;
        uint256 margin;
        uint256 cumulativeFundingEntry;
    }

    function createDerivativeMarketOrder(address sender, DerivativeOrder calldata order)
        external
        returns (CreateDerivativeMarketOrderResponse memory response);

    function increasePositionMargin(
        address sender,
        string calldata sourceSubaccountID,
        string calldata destinationSubaccountID,
        string calldata marketID,
        uint256 amount
    ) external returns (bool success);

    /// @dev `decreasePositionMargin` `0xaf78360b` moves margin back to a subaccount. 🔑 It APPLIES the
    /// position's accrued funding first, in the same transaction, which `increasePositionMargin`
    /// does not; a one-unit decrease is how a contract settles funding without trading. It needs
    /// the market's oracle under 60 s old and margin left at or above the maintenance ratio.
    function decreasePositionMargin(
        address sender,
        string calldata sourceSubaccountID,
        string calldata destinationSubaccountID,
        string calldata marketID,
        uint256 amount
    ) external returns (bool success);

    /// @dev Positions on ACTIVE markets only (one on a paused market is not listed), exact, with
    /// `marketID` in lowercase `0x` hex. 🔴 REVERTS ("negatively-signed value cannot be packed into
    /// uint parameter") if any listed position's `cumulativeFundingEntry` is negative: it is the
    /// market's funding index at the position's last fill or margin decrease, and goes negative once
    /// shorts have paid on net (10-16: 712 of 2,015 mainnet positions). Margin is raw: no accrued funding.
    function subaccountPositions(string calldata subaccountID)
        external
        view
        returns (DerivativePosition[] memory positions);

    function createDerivativeLimitOrder(address sender, DerivativeOrder calldata order)
        external
        returns (CreateDerivativeLimitOrderResponse memory response);

    /// @param orderMask 1 (`ANY`) matches the order whatever its kind
    /// @dev Reverts when the order does not exist (filled, cancelled, or cancelled by matching).
    function cancelDerivativeOrder(
        address sender,
        string calldata marketID,
        string calldata subaccountID,
        string calldata orderHash,
        int32 orderMask,
        string calldata cid
    ) external returns (bool success);

    /// @dev The binding declares this nonpayable, but the precompile serves every query under
    /// STATICCALL (it gates only its write methods on read-only), so it is declared `view` here.
    /// Hashes not found are dropped: match the results by `orderHash`.
    function derivativeOrdersByHashes(DerivativeOrdersRequest calldata request)
        external
        view
        returns (TrimmedDerivativeLimitOrder[] memory orders);

    /// @dev `deposit` `0xe441dec9` and `withdraw` `0xeb28c205` move `amount` of bank `denom` (the
    /// token's own units, not the API format) into and out of one of the sender's non-default
    /// subaccounts. Proven from a contract on mainnet on subaccount 1 with USDC (10-12; and 10-16 with
    /// a market short, a resting post-only hold and cancel, a withdrawal while the short was open,
    /// increase/decrease margin and the reduce-only close all on that subaccount).
    function deposit(address sender, string calldata subaccountID, string calldata denom, uint256 amount)
        external
        returns (bool success);

    function withdraw(address sender, string calldata subaccountID, string calldata denom, uint256 amount)
        external
        returns (bool success);

    /// @dev `subaccountDeposit` `0x9e96621f`: a subaccount's balance of `denom` in the token's own
    /// units. 🔴 The exchange keeps it to 18 decimals and this answers each figure ROUNDED TO THE
    /// NEAREST unit (half to even), available and total independently; it reverts if either is
    /// negative. So a withdrawal of the available it answers can be refused: one unit less is always
    /// there. A resting order's margin hold is in the total, not the available. A default subaccount
    /// answers the fraction its whole-unit sweeps to the bank left behind.
    function subaccountDeposit(string calldata subaccountID, string calldata denom)
        external
        view
        returns (uint256 availableBalance, uint256 totalBalance);
}
