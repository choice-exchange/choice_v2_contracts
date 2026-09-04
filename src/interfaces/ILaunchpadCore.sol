// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The subset of `shroom_launchpad`'s `LaunchpadCore` that Choice v2 calls, mirrored
/// from that repo's MIT-licensed `ILaunchpadCore` plus the `extsload` primitive the core
/// exposes for its `LaunchpadViews` satellite.
///
/// The deployed core's whole external view surface is this interface and `extsload` - the
/// `launches` mapping is `internal` and `getLaunch` lives on `LaunchpadViews`, which decodes
/// raw storage words. `creator` and `creatorFeeShareBps` are therefore reachable only through
/// `extsload`; `InfinitySettler._readLaunchSplit` does that read with three layout canaries.
interface ILaunchpadCore {
    enum LaunchState {
        Created, // unused - index 0 is the default storage value
        Trading,
        CurveFilled,
        PendingSettlement,
        Graduated,
        SettlementFailed,
        Refunded,
        Reserved,
        Cancelled
    }

    /// @notice Settler -> core: this launch is `Graduated`. Requires `msg.sender` to be the
    /// settler snapshotted on the launch and the launch to be in `PendingSettlement`.
    function onSettled(uint256 launchId) external;

    function getLaunchState(uint256 launchId) external view returns (LaunchState);
    function getLaunchRealPair(uint256 launchId) external view returns (uint256);
    function getLaunchPairAsset(uint256 launchId) external view returns (IERC20);
    function getLaunchToken(uint256 launchId) external view returns (address);

    /// @notice Total launches ever reserved - ids are dense over `[0, launchCount)`.
    function launchCount() external view returns (uint256);

    /// @notice `n` raw storage words starting at `startSlot`.
    function extsload(bytes32 startSlot, uint256 n) external view returns (bytes32[] memory);
}
