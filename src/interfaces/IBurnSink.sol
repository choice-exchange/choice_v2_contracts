// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Currency} from "infinity-core/src/types/Currency.sol";

/// @notice Destination for the burn half of Choice's protocol revenue.
///
/// Injective's exchange module sweeps two places into the auction basket at the end of each
/// round (`SubaccountKeeper.WithdrawAllAuctionBalances`): the auction SUBACCOUNT's exchange
/// deposit, and the plain BANK BALANCE of `ExchangeAuctionFeesAddress`. Choice v1 reaches the
/// first from CosmWasm; the second is one ERC20 transfer from the EVM. Both work, so this
/// interface exists to let the deployment pick without a controller redeploy - the controller
/// is what the pool manager points at, and swapping a sink is one setter.
///
/// `DirectTransferBurnSink` is the default (one call, no denom map).
/// `ExchangeSubaccountBurnSink` reproduces v1's route and is the fallback.
///
/// @dev The controller transfers the funds to the sink FIRST and then calls `burn`, so an
/// implementation works from its own balance and never pulls.
interface IBurnSink {
    /// @param currency The currency to send on. Native INJ arrives as `Currency.wrap(address(0))`.
    /// @param amount The amount already delivered to this contract.
    function burn(Currency currency, uint256 amount) external;
}
