// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Currency} from "infinity-core/src/types/Currency.sol";

import {StockFixing} from "./StockFixing.sol";
import {StockHedge} from "./StockHedge.sol";
import {StockModule} from "./StockModule.sol";
import {StockOps} from "./StockOps.sol";
import {StockPricing} from "./StockPricing.sol";
import {
    FixingBatch,
    FixingConfig,
    FixingRequest,
    StockConfig,
    StockContext,
    StockLayout,
    StockState,
    StockStorage
} from "./StockTypes.sol";

/// @title StockPublic
/// @notice The first module in a `StockVault`'s chain: the views, the permissionless triggers (prices,
/// the anchor, the hedge, restock settlement) and the fixing lane. A selector it does not know falls
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
        StockHedge.cancelMaker(l.config, l.state, msg.sender == l.keeper);
    }

    function topUpMargin() external delegated nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockHedge.topUpMargin(l.config, l.state, l.ctx);
    }

    /// @notice Book the open restock order's delivery, or expire it past its deadline.
    function settleRestock() external delegated nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockOps.settleRestock(l.state, l.ctx);
    }

    /// @notice Book stock that arrived with no order open.
    function syncWindfall() external delegated nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockOps.syncWindfall(l.state, l.ctx);
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
