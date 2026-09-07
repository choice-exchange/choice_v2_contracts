// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

import {ILaunchPositionLocker} from "../../src/interfaces/ILaunchPositionLocker.sol";
import {PositionLocker} from "../../src/launchpad/PositionLocker.sol";

/// @notice A stand-in for the **1.0.0 PUSH locker**, whose source this repo no longer has:
/// `collect` pays the launchpad's share straight out, and there is **no `claim`**.
///
/// 🔑 That missing function is the whole point (plan A9). `LaunchFeeCranker` calls
/// `LOCKER.claim(...)` unconditionally and wraps it in a `try`, and A6's header claims the wrap
/// is what lets one bytecode serve both locker generations - a claim that had never once been
/// executed against a locker that lacks the function. Calling a selector a contract does not
/// have reverts with EMPTY returndata, which is the same shape that wedged a graduation on
/// 2026-09-06 after passing every gate, so "the try catches it" is worth proving rather than
/// asserting.
///
/// ⚠️ It is a WRAPPER around a real `PositionLocker`, not a re-implementation: the inner locker
/// owns the position and does the real collection, this contract is registered as its
/// `launchpadTreasury`, and it claims its own credit out and forwards it in the same call. The
/// fees under test are therefore real fees from real swaps on a real pool; the only thing
/// modelled is the push.
contract MockPushPositionLocker is ILaunchPositionLocker {
    using CurrencyLibrary for Currency;

    /// @notice The real locker that owns the position. Its `launchpadTreasury` must be THIS
    /// contract, which is what turns its credit into this contract's push.
    PositionLocker public immutable INNER;

    /// @notice Where the pushed share lands - the sink, as on chain.
    address public launchpadTreasury;

    constructor(PositionLocker inner, address treasury) {
        INNER = inner;
        launchpadTreasury = treasury;
    }

    function POSITION_MANAGER() external view override returns (ICLPositionManager) {
        return INNER.POSITION_MANAGER();
    }

    function getPosition(uint256 launchId) external view override returns (LockedPosition memory) {
        PositionLocker.LockedPosition memory p = INNER.getPosition(launchId);
        return LockedPosition({tokenId: p.tokenId, creator: p.creator, creatorBps: p.creatorBps});
    }

    /// @dev Collect through the inner locker, then PUSH what it credited us straight on. The
    /// creator's share stays credited inside the inner locker, exactly as 1.0.0 leaves it there
    /// for the creator to take.
    function collect(uint256 launchId) external override returns (uint256 amount0, uint256 amount1) {
        uint256 tokenId = INNER.getPosition(launchId).tokenId;
        (amount0, amount1) = INNER.collect(launchId);
        (PoolKey memory key,) = INNER.POSITION_MANAGER().getPoolAndPositionInfo(tokenId);
        _push(key.currency0);
        _push(key.currency1);
    }

    function _push(Currency currency) internal {
        // The inner `claim` reverts `NothingToClaim` for a currency the position has not earned,
        // which is the normal state of a pool traded only one way.
        try INNER.claim(currency, address(this)) returns (uint256 amount) {
            if (amount > 0) currency.transfer(launchpadTreasury, amount);
        } catch {}
    }

    /// @dev 🔴 Reverts with EMPTY returndata - byte for byte what the EVM's own dispatcher does
    /// when a contract has no matching function and no fallback. Solidity cannot un-declare an
    /// inherited external function, so this is how "the 1.0.0 locker has no `claim`" is
    /// expressed; what the CALLER observes is identical, which is all the `try` can see.
    function claim(Currency, address) external pure override returns (uint256) {
        assembly ("memory-safe") {
            revert(0, 0)
        }
    }
}
