// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";

/// @notice A stand-in for `CLPositionManager` that answers `getPoolAndPositionInfo` and nothing
/// else.
///
/// The sink and the cranker use exactly one function on the position manager, so the unit tests
/// hold one here rather than the real thing: a real `CLPositionManager` needs Permit2, a WETH9
/// and a descriptor, and none of that is under test when the question is "does the sink refuse a
/// pool key that does not trade the pair". The end-to-end proof against a REAL position manager,
/// a real locker and a real graduation lives in `LaunchFeeCranker.t.sol`.
///
/// It is cast to `ICLPositionManager` at the call site, which is why it does not implement it:
/// only the selector has to match, and matching the whole interface would be pages of stubs.
contract MockPositionManager {
    mapping(uint256 tokenId => PoolKey) internal _keys;

    /// @dev The sink asks for this ONCE, in its constructor, to build derived quote hops from.
    /// It defaults to zero so every test written before derivation existed keeps the pre-1.5.0
    /// behaviour — a zero manager disables derivation and leaves `setQuoteRoute` as the only
    /// source of a hop. A test that wants derivation opts in with `setPoolManager`.
    address internal _poolManager;

    function setPoolManager(address m) external {
        _poolManager = m;
    }

    function clPoolManager() external view returns (address) {
        return _poolManager;
    }

    function setPool(uint256 tokenId, PoolKey memory key) external {
        _keys[tokenId] = key;
    }

    /// @dev The second return is a `CLPositionInfo`, a `uint256` user-defined value type. Raw
    /// `uint256` is the same ABI, and nothing here reads it.
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256) {
        return (_keys[tokenId], 0);
    }
}
