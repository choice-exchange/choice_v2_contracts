// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Currency} from "infinity-core/src/types/Currency.sol";

/// @notice Destination for the burn half of Choice's protocol revenue.
///
/// Choice v1 reaches Injective's burn auction from CosmWasm by depositing into its own
/// exchange subaccount and then `ExternalTransfer`-ing to the auction subaccount
/// `0x1111…1111`. Both calls exist on the `0x65` precompile, and under MTS a plain bank
/// transfer to the 20-byte form of that subaccount may be a one-call shortcut. Which of the
/// two the auction module actually credits is an on-chain question that only testnet can
/// answer (plan D8), so the controller holds this behind an interface: the losing
/// implementation is swapped out with one setter instead of a controller redeploy, and the
/// controller is what the pool manager points at.
///
/// @dev The controller transfers the funds to the sink FIRST and then calls `burn`, so an
/// implementation works from its own balance and never pulls.
interface IBurnSink {
    /// @param currency The currency to send on. Native INJ arrives as `Currency.wrap(address(0))`.
    /// @param amount The amount already delivered to this contract.
    function burn(Currency currency, uint256 amount) external;
}
