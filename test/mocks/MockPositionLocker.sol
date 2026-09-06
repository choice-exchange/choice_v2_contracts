// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Currency} from "infinity-core/src/types/Currency.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

import {ILaunchPositionLocker} from "../../src/interfaces/ILaunchPositionLocker.sol";

/// @notice A `PositionLocker` stand-in for the sink's unit tests: a launch id maps to a token
/// id and nothing else happens.
///
/// The registration path is what the real locker guards, and it is tested against the real
/// contract elsewhere. What the SINK needs from a locker is two views, and what its tests need
/// is the ability to say "this launch is registered here, in this position" - including the
/// cases a real settler would never create, which is the whole point of the argument checks.
contract MockPositionLocker is ILaunchPositionLocker {
    ICLPositionManager internal immutable _POSITION_MANAGER;
    address public launchpadTreasury;

    mapping(uint256 launchId => LockedPosition) internal _positions;

    constructor(ICLPositionManager positionManager_, address treasury) {
        _POSITION_MANAGER = positionManager_;
        launchpadTreasury = treasury;
    }

    function POSITION_MANAGER() external view override returns (ICLPositionManager) {
        return _POSITION_MANAGER;
    }

    function register(uint256 launchId, uint256 tokenId) external {
        _positions[launchId] = LockedPosition({tokenId: tokenId, creator: address(0xC12A), creatorBps: 7000});
    }

    function getPosition(uint256 launchId) external view override returns (LockedPosition memory) {
        return _positions[launchId];
    }

    function collect(uint256) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function claim(Currency, address) external pure override returns (uint256) {
        return 0;
    }
}
