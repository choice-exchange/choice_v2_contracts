// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {MarketCalendar} from "../stock/MarketCalendar.sol";
import {
    FixingBatch,
    FixingConfig,
    FixingRequest,
    IssuerQuote,
    RedeemEpoch,
    StockConfig,
    StockContext,
    StockState
} from "../stock/StockTypes.sol";

/// @notice The functions a `StockVault` answers through its fallback: its module chain, `StockPublic`
/// then `StockAdmin`. Call them on the vault's address; the vault's own ABI plus this one is the whole
/// surface.
interface IStockVaultExtension {
    // views
    function config() external view returns (StockConfig memory);
    function state() external view returns (StockState memory);
    function context() external view returns (StockContext memory);
    function roles() external view returns (address keeper, address guardian, address issuer);
    function isDepositor(address depositor) external view returns (bool);
    function stock() external view returns (address);
    function fixingConfig() external view returns (FixingConfig memory);
    function fixingBatch(uint64 boundary) external view returns (FixingBatch memory);
    function fixingRequest(uint256 id) external view returns (FixingRequest memory);
    function quoteDigest(IssuerQuote calldata q) external view returns (bytes32);
    function quoteSigner() external view returns (address);
    function registry() external view returns (address);
    function restockMemo() external view returns (bytes memory);
    function actionPending() external view returns (bool);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256);
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256);
    function claimableRedeem(address controller) external view returns (uint256 cashOut, uint256 stockOut);
    function isOperator(address controller, address operator) external view returns (bool);
    function redeemQueue(uint64 epoch) external view returns (uint64 open, uint64 unwinding, RedeemEpoch memory e);

    // permissionless
    function pushPrice(bytes calldata update) external returns (uint256);
    function poke() external;
    function confirmHedge() external;
    function syncHedge() external returns (bool);
    function cancelMaker() external;
    function topUpMargin() external;
    function settleRestock() external;
    function syncWindfall() external;
    function syncRatio() external;

    // redeem queue
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256);
    function setOperator(address operator, bool approved) external returns (bool);
    function settleRedeems() external;
    function startInKind() external;
    function finishInKind() external;
    function claimRedeem(address controller, address receiver) external returns (uint256 cashOut, uint256 stockOut);

    // fixing lane
    function commitFixing(uint64 boundary, bool cashIn, uint256 amountIn, address recipient)
        external
        returns (uint256 id);
    function settleFixing(uint64 boundary, bytes calldata update) external;
    function claimFixing(uint256 id) external returns (uint256 out, uint256 refund);

    // keeper (and pausers)
    function restock(bool sell, uint256 amountIn, uint256 limitOut, uint16 expiryUnits) external;
    function placeMaker(uint256 price) external returns (bool placed);
    function fillQuote(IssuerQuote calldata q, bytes calldata sig) external;
    function widen(uint16 bps, uint32 duration) external;
    function toClaims(bool isCash, uint256 amount) external;
    function fromClaims(bool isCash, uint256 amount) external;
    function pause(uint8 flags) external;
    function haltAction() external;

    // owner
    function setConfig(StockConfig calldata config_) external;
    function setFixingConfig(FixingConfig calldata fixing_) external;
    function setRoles(address keeper_, address guardian_, address issuer_) external;
    function setQuoteSigner(address signer) external;
    function setCalendar(MarketCalendar calendar_) external;
    function setAllowlist(bool on) external;
    function setDepositor(address depositor, bool allowed) external;
    function setCurveOpen(bool open) external;
    function unpause(uint8 flags) external;
    function acceptAction(uint56 ratio, uint16 maxMoveBps) external;
    function migrateMarket(string calldata marketId_) external;
    function setRestockMemo(bytes calldata memo) external;
    function acceptNav() external;
    function sweep(address token, address to, uint256 amount) external;
}
