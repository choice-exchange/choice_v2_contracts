// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title StockRegistry
/// @notice Every stock vault of a deployment, the issuer of its stock, and a cap on how much of any one
/// issuer's tokens the vaults together may hold.
///
/// **The cap is a static allocation.** Each vault's inventory cap (`maxInventory`) is its allocation
/// under its issuer, and the allocations of one issuer's vaults may never sum past that issuer's cap.
/// A vault asks here whenever its owner changes the cap (`allocate`); lowering always passes, raising
/// past the issuer's room is refused. Live holdings stay under each vault's own cap, so the cap across
/// vaults holds without any fill ever reading this contract. It bounds what one issuer failing, or
/// burning holders' tokens, can cost.
///
/// The issuer here is an identity fixed when a vault is registered (the token's issuer), not the
/// address a vault sends orders to, which its owner may replace.
contract StockRegistry is Ownable2Step {
    struct Issuer {
        uint96 cap;
        uint96 allocated;
    }

    address public factory;
    mapping(address issuer => Issuer) public issuers;
    mapping(address vault => address issuer) public issuerOf;
    mapping(address vault => uint96 allocation) public allocationOf;
    mapping(address stock => address vault) public vaultOf;
    address[] internal _vaults;

    error NotFactory();
    error NotRegistered(address vault);
    error AlreadyRegistered(address stock);
    error OverIssuerCap(uint256 wanted, uint256 room);
    error ZeroAddress();

    event FactorySet(address factory);
    event IssuerCapSet(address indexed issuer, uint256 cap);
    event VaultRegistered(address indexed vault, address indexed stock, address indexed issuer, uint256 allocation);
    event Allocated(address indexed vault, uint256 allocation);

    constructor(address owner_) Ownable(owner_) {}

    // -------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    function vaultAt(uint256 k) external view returns (address) {
        return _vaults[k];
    }

    /// @notice How much more of `issuer`'s cap the vaults may be allocated.
    function room(address issuer) public view returns (uint256) {
        Issuer storage i = issuers[issuer];
        return i.cap > i.allocated ? i.cap - i.allocated : 0;
    }

    // -------------------------------------------------------------------------------------
    // Owner
    // -------------------------------------------------------------------------------------

    function setFactory(address factory_) external onlyOwner {
        factory = factory_;
        emit FactorySet(factory_);
    }

    /// @notice Set `issuer`'s cap, cash value. A cap below what is already allocated stands, and
    /// only stops further raises.
    function setIssuerCap(address issuer, uint96 cap) external onlyOwner {
        if (issuer == address(0)) revert ZeroAddress();
        issuers[issuer].cap = cap;
        emit IssuerCapSet(issuer, cap);
    }

    // -------------------------------------------------------------------------------------
    // Factory and vaults
    // -------------------------------------------------------------------------------------

    /// @notice Record a new vault for `stock`, issued by `issuer`, allocated `allocation`. One vault
    /// per stock token. The factory, or the owner for a vault deployed by hand.
    function register(address vault, address stock, address issuer, uint96 allocation) external {
        if (msg.sender != factory && msg.sender != owner()) revert NotFactory();
        if (vault == address(0) || stock == address(0) || issuer == address(0)) revert ZeroAddress();
        if (vaultOf[stock] != address(0)) revert AlreadyRegistered(stock);
        uint256 left = room(issuer);
        if (allocation > left) revert OverIssuerCap(allocation, left);
        vaultOf[stock] = vault;
        issuerOf[vault] = issuer;
        allocationOf[vault] = allocation;
        issuers[issuer].allocated += allocation;
        _vaults.push(vault);
        emit VaultRegistered(vault, stock, issuer, allocation);
    }

    /// @notice A vault's new inventory cap. Called by the vault itself when its owner sets its config.
    function allocate(uint96 allocation) external {
        address issuer = issuerOf[msg.sender];
        if (issuer == address(0)) revert NotRegistered(msg.sender);
        uint96 old = allocationOf[msg.sender];
        if (allocation > old) {
            uint256 left = room(issuer);
            if (allocation - old > left) revert OverIssuerCap(allocation, left + old);
            issuers[issuer].allocated += allocation - old;
        } else {
            issuers[issuer].allocated -= old - allocation;
        }
        allocationOf[msg.sender] = allocation;
        emit Allocated(msg.sender, allocation);
    }
}
