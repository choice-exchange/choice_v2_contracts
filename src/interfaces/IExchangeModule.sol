// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @notice The two `0x65` exchange-precompile methods Choice's burn leg needs.
/// @dev Signatures taken from injective-core's abigen bindings
/// (`injective-chain/modules/evm/precompiles/bindings/cosmos/precompile/exchange`);
/// `externalTransfer` is selector `0xc01307d2`. Only the methods used here are declared -
/// the full precompile is large and a partial interface cannot drift into a wrong selector.
interface IExchangeModule {
    /// @notice Move bank funds into an exchange subaccount.
    function deposit(address sender, string calldata subaccountID, string calldata denom, uint256 amount)
        external
        returns (bool success);

    /// @notice Move funds between subaccounts of different owners.
    function externalTransfer(
        address sender,
        string calldata sourceSubaccountID,
        string calldata destinationSubaccountID,
        string calldata denom,
        uint256 amount
    ) external returns (bool success);
}
