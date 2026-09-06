// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Currency} from "infinity-core/src/types/Currency.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

/// @title ILaunchPositionLocker
/// @notice The part of `PositionLocker` that other contracts in this repo call.
///
/// 🔴 **This file is one half of a lockstep ABI, and the other half is deployed.** On
/// 2026-09-06 a settler built against a locker whose `register` had gained an argument
/// reverted with EMPTY returndata after passing every gate, and wedged a graduation. The
/// same trap lives here: `BuybackBurnSink` and `LaunchFeeCranker` call a locker through this
/// interface, and a locker that does not speak it fails the same silent way.
///
/// Two things keep it honest, because a comment does not:
///
/// - `test_theLockerInterfaceMatchesTheDeployedLocker` calls a real `PositionLocker` through
///   this interface for every function below. A selector that drifts fails to compile or
///   reverts there, which is where somebody is looking.
/// - `BuybackBurnSink.setLockers` reads `POSITION_MANAGER()` off each candidate and refuses
///   one that does not answer with the manager it was built against. A contract that is not a
///   locker at all cannot be installed.
///
/// ⚠️ It deliberately does NOT declare `register`. That is the function whose signature
/// changed between locker 1.0.0 and 1.1.0, and nothing here calls it - only the settler does,
/// and the settler holds its locker as an immutable for exactly that reason. Keeping it out
/// means BOTH locker generations satisfy this interface, which is what lets one sink serve the
/// launches of both.
interface ILaunchPositionLocker {
    /// @dev Layout-identical in locker 1.0.0 and 1.1.0: `getPosition` returns
    /// `(uint256,address,uint16)` in both, so the selector and the decode are the same.
    struct LockedPosition {
        uint256 tokenId;
        address creator;
        uint16 creatorBps;
    }

    /// @notice The position manager holding every position this locker owns. Immutable there,
    /// which is what makes it usable as an identity check.
    function POSITION_MANAGER() external view returns (ICLPositionManager);

    /// @notice Where the non-creator share of a collect goes. Owner-settable, so read it, never
    /// assume it: this field IS the sprout revenue feed (plan B6), and it has pointed at three
    /// different addresses.
    function launchpadTreasury() external view returns (address);

    /// @notice A graduated launch's locked seed position. `tokenId == 0` means not registered.
    function getPosition(uint256 launchId) external view returns (LockedPosition memory);

    /// @notice Pull the accrued LP fees out of the position and split them.
    /// @dev Reverts `NothingToCollect` when there is nothing accrued. Locker 1.1.0 CREDITS the
    /// split and `claim` pays it; locker 1.0.0 pushes it in this same call.
    function collect(uint256 launchId) external returns (uint256 amount0, uint256 amount1);

    /// @notice Pay a recipient what `collect` credited it.
    /// @dev Reverts `NothingToClaim` when the credit is zero. ⚠️ Locker 1.0.0 does not have
    /// this function at all - a call to it reverts with empty returndata, which is why every
    /// caller in this repo wraps it.
    function claim(Currency currency, address recipient) external returns (uint256 amount);
}
