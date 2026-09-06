// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";

/// @title IChoiceFeeController
/// @notice The one function `InfinitySettler` needs from `ChoiceFeeController`.
///
/// @dev Declared as an interface rather than importing the contract so the settler depends on
/// a call, not on a deployment. The controller is discovered at graduation time from
/// `IProtocolFees.protocolFeeController()`, which is the only address the pool manager will
/// accept a `setProtocolFee` from - so this can never be pointed at a stale one.
interface IChoiceFeeController {
    /// @notice Set a launchpad graduation pool's protocol fee to zero.
    /// @dev Permissionless, and gated on `key.hooks` being the launch-pool guard hook.
    function zeroLaunchPoolProtocolFee(PoolKey memory key) external;
}
