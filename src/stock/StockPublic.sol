// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Currency} from "infinity-core/src/types/Currency.sol";

import {StockFixing} from "./StockFixing.sol";
import {StockHedge} from "./StockHedge.sol";
import {StockModule} from "./StockModule.sol";
import {StockLib} from "./StockLib.sol";
import {StockPricing} from "./StockPricing.sol";
import {StockQueue} from "./StockQueue.sol";
import {StockQuotes} from "./StockQuotes.sol";
import {StockRestock} from "./StockRestock.sol";
import {
    DepositLock,
    FixingBatch,
    FixingConfig,
    FixingRequest,
    IssuerQuote,
    RedeemEpoch,
    StockConfig,
    StockContext,
    StockLayout,
    StockState,
    StockStorage
} from "./StockTypes.sol";

/// @title StockPublic
/// @notice The first module in a `StockVault`'s chain: the views, the permissionless triggers (prices,
/// the anchor, the hedge, restock settlement), the fixing lane and the redeem queue. A selector it does not know falls
/// through to `NEXT` (`StockAdmin`), so the vault's whole surface is this module plus the next, fixed at
/// deployment. One deployment serves every vault.
contract StockPublic is StockModule {
    /// @notice The next module in the chain.
    address public immutable NEXT;

    constructor(address next) {
        if (next.code.length == 0) revert ZeroAddress();
        NEXT = next;
    }

    /// @notice Every selector this module does not define runs in `NEXT`, still as the vault.
    fallback() external {
        _delegated();
        address next = NEXT;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), next, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }

    // -------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------

    function config() external view delegated returns (StockConfig memory) {
        return StockStorage.layout().config;
    }

    function state() external view delegated returns (StockState memory) {
        return StockStorage.layout().state;
    }

    function context() external view delegated returns (StockContext memory) {
        return StockStorage.layout().ctx;
    }

    function roles() external view delegated returns (address keeper, address guardian, address issuer) {
        StockLayout storage l = StockStorage.layout();
        return (l.keeper, l.guardian, l.issuer);
    }

    function isDepositor(address depositor) external view delegated returns (bool) {
        StockLayout storage l = StockStorage.layout();
        return !l.allowlistOn || l.isDepositor[depositor];
    }

    function stock() external view delegated returns (address) {
        return Currency.unwrap(StockStorage.layout().ctx.stock);
    }

    function fixingConfig() external view delegated returns (FixingConfig memory) {
        return StockStorage.layout().fixing;
    }

    function fixingBatch(uint64 boundary) external view delegated returns (FixingBatch memory) {
        return StockStorage.layout().batches[boundary];
    }

    function fixingRequest(uint256 id) external view delegated returns (FixingRequest memory) {
        return StockStorage.layout().requests[id];
    }

    /// @notice The EIP-712 digest the quote signer signs for `q` on this vault.
    function quoteDigest(IssuerQuote calldata q) external view delegated returns (bytes32) {
        return StockQuotes.digest(q);
    }

    function quoteSigner() external view delegated returns (address) {
        return StockStorage.layout().quoteSigner;
    }

    function registry() external view delegated returns (address) {
        return StockStorage.layout().registry;
    }

    function restockMemo() external view delegated returns (bytes memory) {
        return StockStorage.layout().restockMemo;
    }

    /// @notice Whether a corporate action is pending: halted, or a ratio announced but not accepted.
    function actionPending() external view delegated returns (bool) {
        return StockLib.actionPending(StockStorage.layout().ctx);
    }

    /// @notice ERC-7540: `controller`'s queued shares not yet settled (`requestId` is always 0).
    function pendingRedeemRequest(uint256, address controller) external view delegated returns (uint256) {
        return StockQueue.pending(StockStorage.layout(), controller);
    }

    /// @notice ERC-7540: `controller`'s settled shares, ready for `claimRedeem`.
    function claimableRedeemRequest(uint256, address controller) external view delegated returns (uint256 shares) {
        (shares,,) = StockQueue.claimable(StockStorage.layout(), controller);
    }

    /// @notice What `claimRedeem` would pay `controller` now.
    function claimableRedeem(address controller) external view delegated returns (uint256 cashOut, uint256 stockOut) {
        (, cashOut, stockOut) = StockQueue.claimable(StockStorage.layout(), controller);
    }

    /// @notice The shares of `holder`'s that recent deposits lock, and until when (zero once free).
    function lockedShares(address holder) external view delegated returns (uint256 shares, uint64 until) {
        DepositLock storage d = StockStorage.layout().depositLocks[holder];
        if (block.timestamp < d.until) return (d.shares, d.until);
    }

    function isOperator(address controller, address operator) external view delegated returns (bool) {
        return StockStorage.layout().operators[controller][operator];
    }

    /// @notice The open epoch, the one in kind waiting for its debt (zero if none), and an epoch's state.
    function redeemQueue(uint64 epoch)
        external
        view
        delegated
        returns (uint64 open, uint64 unwinding, RedeemEpoch memory e)
    {
        StockLayout storage l = StockStorage.layout();
        return (l.redeemEpoch, l.unwinding, l.epochs[epoch]);
    }

    // -------------------------------------------------------------------------------------
    // Permissionless
    // -------------------------------------------------------------------------------------

    /// @notice Store a signed update, so the calls after it in a `multicall` see it.
    function pushPrice(bytes calldata update) external delegated returns (uint256) {
        return StockStorage.layout().ctx.store.update(update);
    }

    function poke() external delegated nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockPricing.poke(l.config, l.state, l.ctx);
    }

    /// @notice The vault's own call, from `StockOps.beforeNav`: see `StockHedge.settleFunding`.
    function settleFunding() external delegated {
        if (msg.sender != address(this)) revert NotSelf();
        StockHedge.settleFunding(StockStorage.layout().state);
    }

    function confirmHedge() external delegated nonReentrant {
        StockHedge.confirmHedge(StockStorage.layout().state);
    }

    function syncHedge() external delegated nonReentrant returns (bool) {
        StockLayout storage l = StockStorage.layout();
        return StockHedge.syncHedge(l.config, l.state, l.ctx, _restockOpen(l), msg.sender == l.keeper);
    }

    /// @notice Cancel the resting maker hedge: the keeper any time, anyone once it has rested
    /// `makerTimeout`.
    function cancelMaker() external delegated nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockHedge.cancelMaker(l.config, l.state, l.ctx, msg.sender == l.keeper);
    }

    function topUpMargin() external delegated nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockHedge.topUpMargin(l.config, l.state, l.ctx, msg.sender == l.keeper);
    }

    /// @notice Close the open restock order on what has arrived. Anyone. See `StockRestock.settle`.
    function settleRestock() external delegated nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockRestock.settle(l.state, l.ctx);
    }

    /// @notice Book stock and cash that arrived with no order open.
    function syncWindfall() external delegated nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockRestock.syncWindfall(l.state, l.ctx);
    }

    /// @notice Make a ratio the registry announces a standing halt, so the vault stays halted until
    /// the owner accepts it even if the announcement is withdrawn. Anyone.
    function syncRatio() external delegated {
        StockContext storage ctx = StockStorage.layout().ctx;
        if (!ctx.actionHalt && StockLib.actionPending(ctx)) {
            ctx.actionHalt = true;
            emit ActionHalted(msg.sender);
        }
    }

    // -------------------------------------------------------------------------------------
    // Redeem queue (see `StockQueue`)
    // -------------------------------------------------------------------------------------

    /// @notice ERC-7540: queue `shares` of `owner` for `controller`. Returns request id 0.
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        delegated
        nonReentrant
        returns (uint256)
    {
        StockQueue.request(StockStorage.layout(), shares, controller, owner);
        return 0;
    }

    /// @notice ERC-7540: let `operator` request and claim for the caller.
    function setOperator(address operator, bool approved) external delegated returns (bool) {
        StockQueue.setOperator(StockStorage.layout(), operator, approved);
        return true;
    }

    /// @notice Settle the open epoch in cash, once the cash is there. Anyone.
    function settleRedeems() external delegated nonReentrant {
        StockQueue.settleCash(StockStorage.layout());
    }

    /// @notice Settle the open epoch in kind: the keeper any time, anyone once it is overdue.
    function startInKind() external delegated nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockQueue.startInKind(l, msg.sender == l.keeper);
    }

    /// @notice Pay the in-kind epoch's debt, once the short is cut and the cash is back. Anyone.
    function finishInKind() external delegated nonReentrant {
        StockQueue.finishInKind(StockStorage.layout());
    }

    /// @notice Pay `controller`'s settled share to `receiver`. The controller or its operator.
    function claimRedeem(address controller, address receiver)
        external
        delegated
        nonReentrant
        returns (uint256 cashOut, uint256 stockOut)
    {
        return StockQueue.claim(StockStorage.layout(), controller, receiver);
    }

    // -------------------------------------------------------------------------------------
    // Fixing lane (see `StockFixing`)
    // -------------------------------------------------------------------------------------

    /// @notice Commit `amountIn` (cash when `cashIn`, else stock) to the next boundary's fixing;
    /// `boundary` must be that next one. The input is taken now and held until `claimFixing`.
    /// @return id the request
    function commitFixing(uint64 boundary, bool cashIn, uint256 amountIn, address recipient)
        external
        delegated
        nonReentrant
        returns (uint256 id)
    {
        return StockFixing.commit(StockStorage.layout(), boundary, cashIn, amountIn, recipient);
    }

    /// @notice Fill the batch for `boundary` at the signed update stamped exactly at its tick.
    function settleFixing(uint64 boundary, bytes calldata update) external delegated nonReentrant {
        StockFixing.settle(StockStorage.layout(), boundary, update);
    }

    /// @notice Pay request `id` to its recipient, once its batch has settled or lapsed.
    function claimFixing(uint256 id) external delegated nonReentrant returns (uint256 out, uint256 refund) {
        return StockFixing.claim(StockStorage.layout(), id);
    }
}
