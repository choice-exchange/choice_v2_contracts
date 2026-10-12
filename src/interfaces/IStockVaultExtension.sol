// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {MarketCalendar} from "../stock/MarketCalendar.sol";
import {StockConfig, StockContext, StockState} from "../stock/StockTypes.sol";

/// @notice The functions a `StockVault` answers through its fallback (`StockVaultExtension`). Call
/// them on the vault's address; the vault's own ABI plus this one is the whole surface.
interface IStockVaultExtension {
    // views
    function config() external view returns (StockConfig memory);
    function state() external view returns (StockState memory);
    function context() external view returns (StockContext memory);
    function roles() external view returns (address keeper, address guardian, address issuer);
    function isDepositor(address depositor) external view returns (bool);
    function stock() external view returns (address);

    // permissionless
    function pushPrice(bytes calldata update) external returns (uint256);
    function poke() external;
    function confirmHedge() external;
    function syncHedge() external returns (bool);
    function topUpMargin() external;
    function settleRestock() external;
    function syncWindfall() external;

    // keeper (and pausers)
    function restock(uint256 cash, uint256 minStockOut, bytes calldata memo) external;
    function widen(uint16 bps, uint32 duration) external;
    function toClaims(bool isCash, uint256 amount) external;
    function fromClaims(bool isCash, uint256 amount) external;
    function pause(uint8 flags) external;

    // owner
    function setConfig(StockConfig calldata config_) external;
    function setRoles(address keeper_, address guardian_, address issuer_) external;
    function setCalendar(MarketCalendar calendar_) external;
    function setAllowlist(bool on) external;
    function setDepositor(address depositor, bool allowed) external;
    function setCurveOpen(bool open) external;
    function unpause(uint8 flags) external;
    function clearRestockHalt() external;
    function acceptNav() external;
    function sweep(address token, address to, uint256 amount) external;
}
