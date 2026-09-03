// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ProtocolFeeController} from "infinity-core/src/ProtocolFeeController.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {IBurnSink} from "../interfaces/IBurnSink.sol";

/// @title ChoiceFeeController
/// @notice Choice's protocol fee controller: upstream's fee policy plus a destination for the
/// money.
///
/// The fee *math* is inherited unchanged from PancakeSwap's audited `ProtocolFeeController`
/// - `protocolFeeForPool`, `getLPFeeFromTotalFee`, the 0.4% cap, the per-pool override via
/// `setProtocolFee`. Reimplementing it here would fork a piece of audited arithmetic for no
/// reason and let it drift on the next upstream bump.
///
/// What this adds is where the collected fee goes. Upstream's `collectProtocolFee` is
/// `onlyOwner` and takes an arbitrary recipient, which makes protocol revenue a manual,
/// trusted, owner-shaped action. Choice's revenue policy is fixed in advance instead:
/// `harvest` is permissionless and always splits `treasuryBps` to the treasury and the
/// remainder to the burn auction. Anyone can call it, nobody can redirect it, and the
/// split is visible on chain rather than in a keeper's config.
///
/// The owner is the timelock (plan D13). `collectProtocolFee` stays inherited as an escape
/// hatch for a currency the sink cannot handle.
///
/// @dev One operational limit inherited from the chain, not from this contract: Injective
/// only sweeps a denom into the auction basket if it is on the exchange's auction-transfer
/// denom list, which is set by genesis or by governance proposal
/// (`UpdateAuctionExchangeTransferDenomDecimalsProposal`). Choice earns fees in whatever a
/// pool trades, so a long-tail launch token generally will NOT be on that list, and its burn
/// share would accumulate at the auction address rather than being burnt. Options, none of
/// which belong in this contract: route non-eligible currencies through a swap to INJ before
/// burning, or set a per-pool `treasuryBps` of 100% for them. Decide per currency before
/// pointing a pool's fees at the burn leg.
contract ChoiceFeeController is ProtocolFeeController {
    using CurrencyLibrary for Currency;

    /// @notice Denominator for `treasuryBps`.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Share of harvested revenue kept by the treasury; the remainder is burnt.
    /// @dev Plan D10: 50/50, which puts the burn contribution on the 0.30% tier at v1's
    /// 0.05% while the treasury earns the same again.
    uint256 public treasuryBps = 5_000;

    /// @notice Receives the treasury half of every harvest.
    address public treasury;

    /// @notice Receives the burn half. See `IBurnSink` for why this is pluggable.
    IBurnSink public burnSink;

    error TreasuryNotSet();
    error BurnSinkNotSet();
    error InvalidTreasuryBps();
    error NothingToHarvest();

    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event BurnSinkUpdated(address oldBurnSink, address newBurnSink);
    event TreasuryBpsUpdated(uint256 oldTreasuryBps, uint256 newTreasuryBps);
    event Harvested(Currency indexed currency, uint256 toTreasury, uint256 toBurn);

    constructor(address _poolManager, address _treasury, IBurnSink _burnSink) ProtocolFeeController(_poolManager) {
        treasury = _treasury;
        burnSink = _burnSink;
    }

    /// @notice Pull everything the pool manager holds for `currency` and split it.
    /// @dev Permissionless on purpose: protocol revenue should not sit behind a keeper's
    /// liveness or an owner's discretion. There is nothing to grief - the destinations are
    /// fixed, so a caller can only choose *when* Choice gets paid, and they pay the gas.
    /// @return toTreasury Amount sent to the treasury.
    /// @return toBurn Amount sent to the burn sink.
    function harvest(Currency currency) external returns (uint256 toTreasury, uint256 toBurn) {
        address _treasury = treasury;
        IBurnSink _burnSink = burnSink;
        if (_treasury == address(0)) revert TreasuryNotSet();
        if (address(_burnSink) == address(0)) revert BurnSinkNotSet();

        // Measure what actually arrived rather than trusting the requested amount: a
        // fee-on-transfer currency delivers less than it is asked for, and splitting the
        // requested figure would send out more than we hold and revert on the second leg.
        uint256 balanceBefore = currency.balanceOfSelf();
        IProtocolFees(poolManager).collectProtocolFees(address(this), currency, 0);
        uint256 collected = currency.balanceOfSelf() - balanceBefore;
        if (collected == 0) revert NothingToHarvest();

        toTreasury = collected * treasuryBps / BPS_DENOMINATOR;
        // The remainder rather than a second multiplication, so integer division cannot
        // strand dust in this contract on every single harvest.
        toBurn = collected - toTreasury;

        if (toTreasury > 0) currency.transfer(_treasury, toTreasury);
        if (toBurn > 0) {
            // Deliver first, then notify: the sink works from its own balance and never
            // pulls, so it needs no allowance and cannot reach back into the controller.
            currency.transfer(address(_burnSink), toBurn);
            _burnSink.burn(currency, toBurn);
        }

        emit Harvested(currency, toTreasury, toBurn);
    }

    /// @notice How much a harvest of `currency` would move right now.
    /// @dev For keepers and dashboards deciding whether a harvest is worth its gas.
    function pendingProtocolFee(Currency currency) external view returns (uint256) {
        return IProtocolFees(poolManager).protocolFeesAccrued(currency);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert TreasuryNotSet();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function setBurnSink(IBurnSink newBurnSink) external onlyOwner {
        if (address(newBurnSink) == address(0)) revert BurnSinkNotSet();
        emit BurnSinkUpdated(address(burnSink), address(newBurnSink));
        burnSink = newBurnSink;
    }

    /// @param newTreasuryBps 5000 = half to treasury, half burnt.
    function setTreasuryBps(uint256 newTreasuryBps) external onlyOwner {
        if (newTreasuryBps > BPS_DENOMINATOR) revert InvalidTreasuryBps();
        emit TreasuryBpsUpdated(treasuryBps, newTreasuryBps);
        treasuryBps = newTreasuryBps;
    }

    /// @dev Native INJ arrives here from `collectProtocolFees`.
    receive() external payable {}
}
