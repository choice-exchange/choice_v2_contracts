// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The launchpad's graduation seam, mirrored from
/// `shroom_launchpad/contracts/src/interfaces/IGraduationSettler.sol` (MIT, hence the
/// identifier above rather than this repo's GPL). Copied rather than imported: the two repos
/// are not submodules of one another and this is the entire surface between them.
///
/// `LaunchpadCore.triggerGraduation` transfers both legs to the settler and then calls
/// `settle`. Everything after that is the settler's business - the core only learns the
/// outcome through `ILaunchpadCore.onSettled` / `onSettlementFailed`.
interface IGraduationSettler {
    /// @param launchId Identifier assigned by `LaunchpadCore` at creation.
    /// @param poolTokenAmount The exact curve-derived launch-token amount the core just
    /// transferred in for the pool seed. The settler MUST forward exactly this - not its own
    /// `balanceOf` - so a pre-graduation donation to the settler cannot inflate the seed
    /// (the launchpad's S-L2).
    function settle(uint256 launchId, uint256 poolTokenAmount) external;
}
