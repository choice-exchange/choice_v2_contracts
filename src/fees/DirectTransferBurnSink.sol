// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {IBurnSink} from "../interfaces/IBurnSink.sol";

/// @notice Burn sink A: one plain transfer to the exchange auction-fees address.
///
/// Confirmed against `injective-core`, not assumed. `SubaccountKeeper.WithdrawAllAuctionBalances`
/// sweeps into the auction module from TWO places at the end of each auction round: the
/// exchange deposit held by the auction subaccount, and the plain BANK BALANCE of
/// `ExchangeAuctionFeesAddress`. That address is
/// `sdk.AccAddress(common.HexToAddress(AuctionSubaccountID.Hex()))`, i.e. the low 20 bytes of
/// the all-ones subaccount - `0x1111…1111` as an EVM address, `inj1zyg3zyg…t5qxqh` in bech32.
/// Upstream's own comment on it reads: "Kept for backward compatibility with external senders
/// (e.g. smart contracts) that already send funds here." It carried live INJ, peggy USDT, an
/// IBC denom and an `erc20:` denom when this was checked on 2026-09-04.
///
/// Under MTS an ERC20 balance IS the bank balance, so an ordinary `transfer` here needs no
/// precompile call, no subaccount and no denom string - which is why this is the default sink
/// and `ExchangeSubaccountBurnSink` is the fallback rather than the other way round.
///
/// Two caveats that apply to BOTH sinks:
///
/// 1. Only denoms on the exchange's auction-transfer list are swept. That list is set by
///    genesis or by an `UpdateAuctionExchangeTransferDenomDecimalsProposal` governance
///    proposal - it is not permissionless. A fee currency that is not on it accumulates here
///    untouched instead of reaching the basket. See `ChoiceFeeController`'s notes.
/// 2. Contributions land in the NEXT auction round, never the current one.
///
/// Upstream marks this address legacy and points new integrations at
/// `auctiontypes.AuctionFeesSubaccountAddress`. That one is a 32-byte module-derived address
/// (`inj18kc70l7…3a8gx9`), so an EVM contract cannot address it at all: a 20-byte EVM address
/// cannot name it. Until a precompile exposes it, the two paths here are the only ones the
/// EVM has.
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
