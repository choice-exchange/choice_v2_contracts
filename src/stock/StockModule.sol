// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {StockLib} from "./StockLib.sol";
import {StockLayout, StockStorage} from "./StockTypes.sol";

/// @title StockModule
/// @notice The base of every module a `StockVault` reaches through its fallback (`StockPublic`, then
/// `StockAdmin`). A module runs by DELEGATECALL, as the vault, on the vault's storage (`StockStorage`);
/// called directly it refuses everything, so its own (empty) storage can never matter. Its reentrancy
/// lock is the vault's: `ReentrancyGuardTransient` keeps it in one fixed transient slot.
///
/// The owner is the vault's own `owner()`, read back from the vault: there is one owner record, in the
/// vault's `Ownable2Step`.
abstract contract StockModule is ReentrancyGuardTransient {
    address private immutable SELF;

    error NotDelegated();
    error NotSelf();
    error NotOwner();
    error NotKeeper();
    error NotPauser();
    error ZeroAddress();

    /// @notice A corporate action halted the vault: by hand (`by` = who), or a ratio change seen.
    event ActionHalted(address indexed by);

    constructor() {
        SELF = address(this);
    }

    modifier delegated() {
        _delegated();
        _;
    }

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    modifier onlyKeeper() {
        _onlyKeeper();
        _;
    }

    /// @dev Whether the issuer can be ordered from now: then the short tracks the target inventory.
    function _restockOpen(StockLayout storage l) internal view returns (bool) {
        return l.issuer != address(0) && l.state.paused & StockLib.PAUSE_RESTOCK == 0;
    }

    function _owner() internal view returns (address) {
        return IOwnerOf(address(this)).owner();
    }

    function _delegated() internal view {
        if (address(this) == SELF) revert NotDelegated();
    }

    function _onlyOwner() internal view {
        _delegated();
        if (msg.sender != _owner()) revert NotOwner();
    }

    function _onlyKeeper() internal view {
        _delegated();
        if (msg.sender != StockStorage.layout().keeper) revert NotKeeper();
    }

    /// @dev The guardian, the keeper or the owner: who may pause and halt.
    function _pauser() internal view {
        StockLayout storage l = StockStorage.layout();
        if (msg.sender != l.guardian && msg.sender != l.keeper && msg.sender != _owner()) revert NotPauser();
    }

    function _keeperOrOwner() internal view {
        if (msg.sender != StockStorage.layout().keeper && msg.sender != _owner()) revert NotKeeper();
    }
}

interface IOwnerOf {
    function owner() external view returns (address);
}
