// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ProtocolFeeController} from "infinity-core/src/ProtocolFeeController.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
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
/// It also carries one thing that is not about Choice's revenue but about keeping somebody
/// else's out of it: `zeroLaunchPoolProtocolFee`. `protocolFeesAccrued` is ONE global bucket
/// per currency across every pool in the manager, so once a sprout.fun graduate pays into it
/// its share is indistinguishable from a wINJ/USDC pool's by the time anyone can harvest.
/// Rather than try to sweep a share that cannot be told apart, graduates pay no protocol fee
/// at all - then the bucket holds only Choice's own revenue *by construction* (plan A0, D30,
/// D31). See that function for why it is permissionless and what stops it touching any other
/// pool.
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
    using PoolIdLibrary for PoolKey;

    /// @notice Denominator for `treasuryBps`.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Share of harvested revenue kept by the treasury; the remainder is burnt.
    ///
    /// @dev Ships PARKED at 100%: everything goes to the treasury and nothing is burnt, so
    /// the contract is deployable and harvestable before the burn path is settled. This does
    /// not change what users pay - the protocol share is still 33% of the total fee - only
    /// where Choice's own share lands.
    ///
    /// Turning the burn on is two calls from the timelock, never a redeploy:
    /// `setBurnSink(sink)` then `setTreasuryBps(5000)` for plan D10's 50/50, which puts the
    /// burn contribution on the 0.30% tier at v1's 0.05% while the treasury earns the same
    /// again. Do that only once the auction path is settled for the currencies in question -
    /// the sweep is denom-gated by governance, see the note above.
    uint256 public treasuryBps = 10_000;

    /// @notice Receives the treasury half of every harvest.
    address public treasury;

    /// @notice Receives the burn half. See `IBurnSink` for why this is pluggable.
    IBurnSink public burnSink;

    /// @notice The hook that identifies a sprout.fun graduation pool, and the whole gate on
    /// `zeroLaunchPoolProtocolFee`.
    ///
    /// @dev Settable rather than immutable for two reasons. The deploy order is one: the fee
    /// controllers go out in script 02 and the guard hook does not exist until script 05, so
    /// a constructor argument could not be filled. The other is that `InfinitySettler.hooks`
    /// is itself configuration - a future `LaunchFeeHook` (plan D11) changes which hook a
    /// graduate is keyed to, and this has to be able to follow it.
    ///
    /// Zero until the timelock sets it, and the zeroing function refuses to run while it is,
    /// so an unset hook cannot be matched by a hookless pool key.
    ///
    /// 🔑 This grants the owner NO new power. The timelock can already call the inherited
    /// `setProtocolFee(key, 0)` on any pool it likes; what this adds is the ability to let
    /// ANYONE do it, for launch pools only.
    IHooks public launchPoolGuardHook;

    error TreasuryNotSet();
    error BurnSinkNotSet();
    error InvalidTreasuryBps();
    error NothingToHarvest();
    error LaunchPoolGuardHookNotSet();
    error NotALaunchPool(IHooks hooks);
    error HookHasNoCode(address hooks);

    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event BurnSinkUpdated(address oldBurnSink, address newBurnSink);
    event TreasuryBpsUpdated(uint256 oldTreasuryBps, uint256 newTreasuryBps);
    event Harvested(Currency indexed currency, uint256 toTreasury, uint256 toBurn);
    event LaunchPoolGuardHookUpdated(IHooks oldHook, IHooks newHook);
    event LaunchPoolProtocolFeeZeroed(PoolId indexed poolId);

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
        if (_treasury == address(0)) revert TreasuryNotSet();

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
            // Only required when something is actually being burnt, so the parked
            // configuration (treasuryBps = 100%) needs no sink at all. Checked here rather
            // than up front so a missing sink cannot silently strand the burn share.
            IBurnSink _burnSink = burnSink;
            if (address(_burnSink) == address(0)) revert BurnSinkNotSet();

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

    /// @notice Set a sprout.fun graduation pool's protocol fee to zero, so Choice's revenue
    /// and sprout's never mix. Anyone may call it, and it can reach nothing else.
    ///
    /// @dev Plan A0 / tokenomics D30, D31. The separation this makes is structural rather
    /// than procedural: with graduates paying nothing into `protocolFeesAccrued`, a Choice
    /// harvest provably cannot move sprout money, and it stays provable from the pool key
    /// instead of from an operator's promise. The trader pays the same 1% either way - the
    /// settler's LP fee carries the whole tier (10000 pips) rather than the 6722 that
    /// composited to 1% *alongside* a protocol leg.
    ///
    /// 🔴 It has to be a new function rather than a policy override.
    /// `ProtocolFeeController.protocolFeeForPool` is `override` WITHOUT `virtual`, so the
    /// formula cannot be subclassed, and the inherited `setProtocolFee` is `onlyOwner` - and
    /// a timelock call per graduation is not viable when graduation is permissionless.
    ///
    /// 🔑 Permissionless is safe because of the gate, not in spite of it. `key.hooks` is part
    /// of the pool's identity and `LaunchPoolGuardHook` permissions `beforeInitialize` to the
    /// settler alone, so a key that satisfies this check IS a pool the settler created. The
    /// only thing a caller can choose is *when* a graduate stops paying Choice, and the only
    /// direction is down; there is nothing here that can raise a fee or touch a pool that is
    /// not a launch pool.
    ///
    /// `InfinitySettler.settle` calls this in the graduation transaction, so a graduate never
    /// charges the fee for even one block. This staying open is the repair path for a pool
    /// initialised outside `settle`, and it costs nothing to keep.
    ///
    /// Idempotent: setting an already-zero fee to zero is a no-op write, so a second call
    /// succeeds and changes nothing.
    function zeroLaunchPoolProtocolFee(PoolKey memory key) external {
        IHooks hook = launchPoolGuardHook;
        if (address(hook) == address(0)) revert LaunchPoolGuardHookNotSet();
        if (address(key.hooks) != address(hook)) revert NotALaunchPool(key.hooks);
        // Upstream's own check, for the same reason: this contract is the fee controller of
        // exactly one pool manager, and a key naming another one would be answered by that
        // manager's `InvalidCaller` rather than by anything legible.
        if (address(key.poolManager) != poolManager) revert InvalidPoolManager();

        IProtocolFees(address(key.poolManager)).setProtocolFee(key, 0);
        emit LaunchPoolProtocolFeeZeroed(key.toId());
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

    /// @notice Point the launch-pool gate at the hook graduation pools are keyed to.
    /// @dev `address(0)` is allowed and disables `zeroLaunchPoolProtocolFee` entirely - which
    /// is the state a fresh deployment is in, before the launchpad settler exists.
    function setLaunchPoolGuardHook(IHooks newHook) external onlyOwner {
        // A hook with no code answers `getHooksRegistrationBitmap` with empty returndata,
        // which decodes as 0; no pool the manager would accept could be keyed to it. Refusing
        // it here means a fat-fingered address cannot become a gate that matches nothing - or,
        // worse, one that matches some unrelated key by accident.
        if (address(newHook) != address(0) && address(newHook).code.length == 0) {
            revert HookHasNoCode(address(newHook));
        }
        emit LaunchPoolGuardHookUpdated(launchPoolGuardHook, newHook);
        launchPoolGuardHook = newHook;
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
