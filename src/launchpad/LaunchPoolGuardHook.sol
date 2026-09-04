// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {ICLHooks, HOOKS_BEFORE_INITIALIZE_OFFSET} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";

/// @title LaunchPoolGuardHook
/// @notice Makes a launch's graduation pool un-campable: only an allowlisted settler may
/// create it.
///
/// **The attack this closes.** Initialising an Infinity pool is free, permissionless, and
/// sets the price with no liquidity behind it - and a launch token's address is public from
/// `bindLaunchToken` onward. So anyone could open the pool a graduation was going to use, at
/// a price of their choosing, and take the difference from the seed on the first arb. A
/// settler can refuse to seed a mispriced pool, but refusing is a wedge, not a defence: there
/// are only four canonical tiers, so camping all of them costs four times the gas of camping
/// one. Permissioning the initialize is the fix that has no cheaper counter-move.
///
/// **Why this is a cheap hook to live with.** `getHooksRegistrationBitmap` registers
/// `beforeInitialize` and NOTHING else, and `Hooks.validateHookConfig` makes the pool
/// manager reject any pool whose key claims otherwise. So this contract is called exactly
/// once in a pool's life, at creation, and can never be called again - it cannot tax a swap,
/// block a withdrawal, or freeze a pool later, even if it were broken or its owner lost. It
/// also needs no address mining: Infinity carries hook permissions in `PoolKey.parameters`,
/// not in the hook's address bits the way Uniswap v4 does.
///
/// 🔴 `sender` is the `msg.sender` of `CLPoolManager.initialize`, so a settler MUST call the
/// pool manager directly. Going through `CLPositionManager.initializePool` would present the
/// position manager as the caller and this guard would reject it.
///
/// A griefer can still open a HOOKLESS pool for the same token pair - that is a different
/// `PoolKey` and therefore a different pool. It holds no liquidity, nothing routes through
/// it, and the graduation ignores it.
contract LaunchPoolGuardHook is Ownable2Step, IHooks {
    /// @notice `beforeInitialize` only. Deliberately the whole permission set.
    uint16 public constant BITMAP = uint16(1 << HOOKS_BEFORE_INITIALIZE_OFFSET);

    /// @notice Who may create a pool keyed to this hook.
    mapping(address initializer => bool allowed) public isInitializer;

    error NotAnInitializer(address sender);
    error ZeroAddress();

    event InitializerUpdated(address indexed initializer, bool allowed);

    /// @param _owner The timelock.
    /// @param _initializer The settler, whose CREATE3 address is known before it is deployed -
    /// which is what lets this contract be born owned by the timelock rather than handed over.
    constructor(address _owner, address _initializer) Ownable(_owner) {
        if (_owner == address(0) || _initializer == address(0)) revert ZeroAddress();
        isInitializer[_initializer] = true;
        emit InitializerUpdated(_initializer, true);
    }

    /// @inheritdoc IHooks
    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return BITMAP;
    }

    /// @notice Reject any pool creation that does not come from an allowlisted settler.
    /// @param sender `msg.sender` of `CLPoolManager.initialize`.
    function beforeInitialize(address sender, PoolKey calldata, uint160) external view returns (bytes4) {
        if (!isInitializer[sender]) revert NotAnInitializer(sender);
        return ICLHooks.beforeInitialize.selector;
    }

    /// @notice Add or remove a settler. Pools already created are untouched - this hook is
    /// never consulted again after a pool exists.
    function setInitializer(address initializer, bool allowed) external onlyOwner {
        if (initializer == address(0)) revert ZeroAddress();
        isInitializer[initializer] = allowed;
        emit InitializerUpdated(initializer, allowed);
    }
}
