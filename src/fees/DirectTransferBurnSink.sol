// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {IBurnSink} from "../interfaces/IBurnSink.sol";

/// @notice Burn sink candidate A (plan D8): one plain transfer to the auction address.
///
/// Under MTS an ERC20 balance IS the bank balance, so an ordinary transfer to
/// `0x1111…1111` - the 20-byte form of the auction subaccount v1 pays into - moves bank
/// funds to that account with no precompile call and no denom string. If the auction module
/// credits funds held there, this is strictly the better implementation: one call, no
/// per-currency configuration, nothing to keep in sync.
///
/// Whether it does is the open half of D8 and is settled on testnet by harvesting a real fee
/// through this sink and reading the auction balance. Until then
/// `ExchangeSubaccountBurnSink` is the conservative default, being the mechanism v1 has run
/// for years.
contract DirectTransferBurnSink is IBurnSink {
    using CurrencyLibrary for Currency;

    /// @notice The Injective burn-auction subaccount `0x1111…1111` in its 20-byte form.
    address public constant AUCTION = 0x1111111111111111111111111111111111111111;

    event Burnt(Currency indexed currency, uint256 amount);

    /// @inheritdoc IBurnSink
    /// @dev Permissionless: this contract only ever moves its own balance to one hardcoded
    /// address, so an uninvited caller can at most push funds along the path they were
    /// already destined for. Sweeping the whole balance rather than `amount` also means a
    /// transfer that landed here without a `burn` call cannot be stranded.
    function burn(Currency currency, uint256) external {
        uint256 amount = currency.balanceOfSelf();
        if (amount == 0) return;
        currency.transfer(AUCTION, amount);
        emit Burnt(currency, amount);
    }

    receive() external payable {}
}
