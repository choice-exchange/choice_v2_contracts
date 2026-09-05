// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @notice The burn half of Injective's `MintBurnBankERC20`, which is what a launchpad token
/// minted through the bank precompile actually is.
///
/// `burn(uint256)` is stock OpenZeppelin `ERC20Burnable`: it burns the CALLER's own balance and
/// is not owner-gated. That matters more than it looks. The token's `mint` IS owner-gated, so a
/// fixed-supply launch renounces ownership straight after the initial mint - and this interface
/// only exists because that renounce does NOT take the burn with it.
///
/// Verified 2026-09-05 against the real creation bytecode from `MintBurnBankERC20MetaData`
/// (`injective-core`, the same metadata `erc20/keeper/keeper.go:133` deploys from): after
/// `renounceOwnership()`, `mint` reverts `0x118cdaa7` `OwnableUnauthorizedAccount` while
/// `burn(uint256)` succeeds from the ex-owner AND from an unrelated address, and `burnFrom`
/// reverts with an ALLOWANCE error rather than an ownership one. In the runtime dispatch
/// `mint` enters the `_checkOwner` block and `burn` jumps straight to `_burn(msg.sender, value)`
/// without ever reading the owner slot.
///
/// Underneath, `_burn` routes to `burn(address,uint256)` on the bank precompile, so this is a
/// real reduction of BANK supply that `totalSupply()` reflects - not a transfer to a dead
/// address, which is what Pons does and which leaves `totalSupply()` overstated forever.
interface IBurnableERC20 {
    /// @notice Destroy `value` tokens held by the caller, reducing total supply.
    function burn(uint256 value) external;
}
