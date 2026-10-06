// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {
    CLPositionInfo,
    CLPositionInfoLibrary
} from "infinity-periphery/src/pool-cl/libraries/CLPositionInfoLibrary.sol";

/// @notice A stand-in for `CLPositionManager` that answers `getPoolAndPositionInfo` and
/// `getPositionLiquidity`, and nothing else.
///
/// The sink and the cranker use only these two, so the unit tests hold this rather than the real
/// thing. A real `CLPositionManager` needs Permit2, a WETH9 and a descriptor, and none of that is
/// under test when the question is "does the sink refuse a pool key that does not trade the
/// pair". The end-to-end proof against a REAL position manager, a real locker and a real
/// graduation lives in `LaunchFeeCranker.t.sol`.
///
/// It is cast to `ICLPositionManager` at the call site, which is why it does not implement it:
/// only the selector has to match, and matching the whole interface would be pages of stubs.
contract MockPositionManager {
    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    mapping(uint256 tokenId => Position) internal _positions;

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

    /// @dev A full-range position whose liquidity never binds: 1.8.0 sizes a swap against
    /// `min(pool liquidity, this)`, so every test that is about ROUTING keeps sizing against the
    /// pool, exactly as before anchoring existed. The tests about anchoring use `setPosition`.
    function setPool(uint256 tokenId, PoolKey memory key) external {
        _positions[tokenId] = Position(key, -887_200, 887_200, type(uint128).max);
    }

    /// @dev A position with a real range and a real liquidity: what the sink sizes against.
    function setPosition(uint256 tokenId, PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
    {
        _positions[tokenId] = Position(key, tickLower, tickUpper, liquidity);
    }

    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, CLPositionInfo) {
        Position memory p = _positions[tokenId];
        return (p.key, CLPositionInfoLibrary.initialize(p.key, p.tickLower, p.tickUpper));
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128) {
        return _positions[tokenId].liquidity;
    }
}
