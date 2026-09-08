// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLHooks, HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IBinHooks, HOOKS_BEFORE_MINT_OFFSET} from "infinity-core/src/pool-bin/interfaces/IBinHooks.sol";

/// @title PermissionedLiquidityHook
/// @notice Restricts a pool's LIQUIDITY PROVISION to an allowlist. Anyone may still swap.
///
/// **What it is for.** A pool with a designated market maker, where the LP fee is meant to
/// accrue to whoever is quoting it rather than to anyone who deposits alongside. Without this,
/// a third party can provide liquidity into the pool and take a pro-rata cut of every fee it
/// charges - passively, or as a single-block JIT sandwich around a known swap. This hook is the
/// only defence with no cheaper counter-move: it makes the deposit itself impossible rather
/// than merely unprofitable.
///
/// It is a primitive, not a policy. Whether a pool SHOULD be permissioned this way is a
/// question for whoever opens it; a hookless pool remains the default and the right answer for
/// an ordinary public market.
///
/// **Serves both pool types from one deployment.** Infinity numbers the CL "before add
/// liquidity" callback and the Bin "before mint" callback at the SAME bit,
/// `HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET == HOOKS_BEFORE_MINT_OFFSET == 2`, so one bitmap and one
/// contract answer for a CL pool and a Bin pool alike. The two callbacks differ in signature
/// and in RETURN SHAPE and both are implemented below.
///
/// 🔴 **`sender` IS THE DIRECT CALLER, NOT THE DEPOSITOR - AND THAT IS THE ONE WAY TO GET THIS
/// WRONG.** Both dispatchers pass the `msg.sender` of the POOL MANAGER call
/// (`BinHooks.beforeMint`, `CLHooks.beforeAddLiquidity`). Add liquidity the ordinary way, through
/// `BinPositionManager` or `CLPositionManager`, and that address is the POSITION MANAGER - a
/// contract anybody may call. ⇒ **Allowlisting a position manager opens the pool to everyone**
/// and the gate still reads as armed: it reverts for a stranger calling the pool manager
/// directly, which is the test most people would write. `test_allowlistingThePositionManager-
/// FailsOpen` in this repo plants exactly that mistake and proves it.
///
/// ⇒ An allowlisted provider MUST take the vault lock itself and call
/// `poolManager.mint` / `poolManager.modifyLiquidity` directly. That is not a workaround; it
/// falls out anyway. `BinPoolManager.mint` credits shares with `to: msg.sender` and
/// `CLPoolManager.modifyLiquidity` keys the position on `owner: msg.sender`, so a direct call
/// leaves the caller holding the position outright, with no `BinFungibleToken` or ERC721
/// wrapper in between. The cost is that such a position is invisible to the LP UI.
///
/// **What this hook can never do, and it is checkable rather than promised.**
/// `getHooksRegistrationBitmap` returns the add-liquidity bit and NOTHING else, and
/// `Hooks.validateHookConfig` makes the pool manager reject at `initialize` any `PoolKey` whose
/// declared bitmap disagrees. `Hooks.shouldCall` then tests that bit before every callback. So
/// this contract is unreachable on a swap, on a withdrawal, on a donate and on an initialize -
/// it cannot tax flow, cannot block an exit and cannot freeze a pool, even if it were broken or
/// its owner key were lost. Two consequences worth stating plainly:
///
/// - **Withdrawal is never gated.** `beforeRemoveLiquidity` / `beforeBurn` are not registered.
///   `CLHooks` additionally guards its add-liquidity call on `params.liquidityDelta > 0`, and
///   `BinPoolManager.burn` carries no `whenNotPaused`, so an LP can exit a paused pool.
/// - **Swapping is never gated,** which is the limit of what this buys. Outsiders can still
///   trade against the pool and take inventory whenever its price is stale against the wider
///   market. That is the LP fee's job, not this hook's.
///
/// 🔑 Needs no address mining: Infinity carries hook permissions in `PoolKey.parameters`, not in
/// the hook address's leading bits the way Uniswap v4 does.
contract PermissionedLiquidityHook is Ownable2Step, IHooks {
    /// @notice The add-liquidity bit only. Deliberately the whole permission set.
    /// @dev CL's `HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET` and Bin's `HOOKS_BEFORE_MINT_OFFSET` are
    /// the same bit; `test_theTwoPoolTypesShareTheAddLiquidityBit` pins that they stay so.
    uint16 public constant BITMAP = uint16(1 << HOOKS_BEFORE_MINT_OFFSET);

    /// @notice Who may add liquidity to a pool keyed to this hook. See the `sender` warning
    /// above: these are DIRECT callers of the pool manager, never end users.
    mapping(address provider => bool allowed) public isLiquidityProvider;

    error NotALiquidityProvider(address sender);
    error ZeroAddress();

    event LiquidityProviderUpdated(address indexed provider, bool allowed);

    /// @param _owner The timelock.
    /// @param _provider The first allowed provider. Its CREATE3 address is known before it is
    /// deployed, which is what lets this contract be born owned by the timelock rather than
    /// handed over afterwards.
    constructor(address _owner, address _provider) Ownable(_owner) {
        if (_owner == address(0) || _provider == address(0)) revert ZeroAddress();
        isLiquidityProvider[_provider] = true;
        emit LiquidityProviderUpdated(_provider, true);
    }

    /// @inheritdoc IHooks
    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return BITMAP;
    }

    /// @notice Bin pools. Reject a mint that does not come from an allowlisted provider.
    /// @param sender `msg.sender` of `BinPoolManager.mint`.
    /// @dev Returns `(bytes4, uint24)` - 64 bytes - because `BinHooks.beforeMint` requires
    /// exactly that length. The `uint24` is an `lpFeeOverride` and is read ONLY when the pool
    /// carries a dynamic fee; these pools carry a static one, so 0 is both correct and ignored.
    function beforeMint(address sender, PoolKey calldata, IBinPoolManager.MintParams calldata, bytes calldata)
        external
        view
        returns (bytes4, uint24)
    {
        if (!isLiquidityProvider[sender]) revert NotALiquidityProvider(sender);
        return (IBinHooks.beforeMint.selector, 0);
    }

    /// @notice CL pools. Reject an add that does not come from an allowlisted provider.
    /// @param sender `msg.sender` of `CLPoolManager.modifyLiquidity`.
    /// @dev Returns a bare `bytes4`, unlike `beforeMint` above - `Hooks.callHook` checks only
    /// that the returned selector matches the one it called.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view returns (bytes4) {
        if (!isLiquidityProvider[sender]) {
            revert NotALiquidityProvider(sender);
        }
        return ICLHooks.beforeAddLiquidity.selector;
    }

    /// @notice Add or remove a provider. Liquidity already in the pool is untouched: this hook
    /// is never consulted on a withdrawal, so removing a provider stops future deposits and
    /// can never strand existing ones.
    function setLiquidityProvider(address provider, bool allowed) external onlyOwner {
        if (provider == address(0)) revert ZeroAddress();
        isLiquidityProvider[provider] = allowed;
        emit LiquidityProviderUpdated(provider, allowed);
    }
}
