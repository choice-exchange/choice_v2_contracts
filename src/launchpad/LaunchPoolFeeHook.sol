// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {SafeCast} from "infinity-core/src/libraries/SafeCast.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {
    ICLHooks,
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET,
    HOOKS_AFTER_SWAP_OFFSET,
    HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET
} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {IBurnSink} from "../interfaces/IBurnSink.sol";
import {ILaunchpadCore} from "../interfaces/ILaunchpadCore.sol";

/// @title LaunchPoolFeeHook
/// @notice A launch's graduation pool charges its whole trading fee through this hook, always in
/// the pool's QUOTE asset, and credits it to that launch's creator and to the launchpad treasury.
///
/// **The shape.** A pool keyed to this hook carries LP fee 0, and the fee controller zeroes its
/// protocol fee at graduation, so the pool itself charges nothing. The hook takes `FEE_PIPS` (1%)
/// from the quote side of every swap: in `beforeSwap` when the quote is the swap's specified
/// currency, and in `afterSwap` when it is not. Between them that is every swap shape:
///
/// | swap            | the quote is | taken in     | the hook sees                     | fee      |
/// | --------------- | ------------ | ------------ | --------------------------------- | -------- |
/// | buy, exact in   | specified    | `beforeSwap` | the gross `X` the trader pays     | `X * 1%` |
/// | buy, exact out  | unspecified  | `afterSwap`  | the net `P` the pool took         | `P / 99` |
/// | sell, exact in  | unspecified  | `afterSwap`  | the gross `Q` the pool pays out   | `Q * 1%` |
/// | sell, exact out | specified    | `beforeSwap` | the net `R` the trader asked for  | `R / 99` |
///
/// So the fee is always 1% of the GROSS quote - all of what a buyer pays, or all of what the pool
/// pays out on a sell - and exact input costs the same as exact output. Every fee rounds down, so
/// a trader never pays more than 1% and a fee never exceeds the amount it is taken from, which is
/// what keeps `HookDeltaExceedsSwapAmount` out of reach.
///
/// 🔴 **A price-limited swap that fills only partly pays the fee on what it ASKED for** when the
/// quote is the specified side. That fee is fixed in `beforeSwap`, before the pool has swapped
/// anything, and `afterSwap` can only move the unspecified side, so there is nothing that could
/// refund the part that never filled. Router swaps carry no price limit and fill in full; a caller
/// that sets one (a buyback with an impact cap, say) should size its trades so the cap rarely binds.
///
/// **The swap path never transfers a token.** A fee becomes an ERC6909 claim on the vault
/// (`VAULT.mint`): `afterSwap`'s return credits the hook's own address with the fee inside the
/// swapper's lock, and the mint debits it again, so the hook nets to zero there. The fee is split
/// into `creatorOwed[launchId]`, at the launch's own creator share, and `treasuryOwed[quote]`, which
/// takes the remainder so no dust strands. Payouts burn the claim and take the token inside a lock
/// of this contract's own. The swap path does nothing else: no transfer, no call to the core, no
/// loop, and no owner-settable input.
///
/// **Binding a pool to its launch.** `initialize` carries no hook data, so `beforeInitialize` asks
/// the core instead. The launch token is the currency `getLaunchByToken` recognises, the other
/// currency must be that launch's pair asset, and the creator's share is read through `extsload`
/// with the settler's own three canaries: the launch must be `PendingSettlement`, its recorded
/// settler must be `sender`, and the share must be a legal bps. A pool whose launch cannot be
/// resolved fails its own initialization - which reverts the graduation, leaving the launch in
/// `CurveFilled`, rather than opening a pool that pays nobody. One launch binds one pool, and one
/// hook serves one core, as one settler does.
///
/// **It keeps the guard's job too.** Only an allowlisted initializer may create a pool keyed to
/// this hook, for the same reason `LaunchPoolGuardHook` exists: initialising a pool is free and a
/// launch token's address is public before graduation, so an open initializer would let anyone
/// camp the graduation pool at a price of their choosing.
///
/// **Who is paid.** `claimCreator` pays the launch's CURRENT creator, read off the core at the
/// claim, and only that creator may call it - the rule the core's own curve-fee claim follows. So a
/// creator handoff after graduation moves the pool fees with the role, and nobody else can move a
/// launch's credit into the creator's wallet, where it would no longer be tellable apart from any
/// other balance. `harvest` is permissionless: it pays the treasury's whole credit in one quote
/// asset, then notifies the treasury as an `IBurnSink` if it has code.
///
/// **What the owner cannot do.** The fee is a constant and a pool's split is fixed when it is
/// created. There is no pause and no exemption, so no owner action can make a live pool's swap
/// revert or change what it charges. The owner (the timelock) can allowlist initializers, move the
/// treasury, and sweep tokens sent here by mistake - the hook never holds a token of its own, only
/// vault claims, so a sweep cannot reach anything owed.
contract LaunchPoolFeeHook is Ownable2Step, IHooks, ILockCallback {
    using SafeCast for uint256;

    /// @notice The fee, in pips of the gross quote: 1%. A constant, so every pool keyed to this
    /// hook charges it for life. A different fee is a new hook plus one `setPoolConfig`.
    uint24 public constant FEE_PIPS = 10_000;
    uint24 internal constant PIPS_DENOMINATOR = 1_000_000;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice `beforeInitialize`, `beforeSwap`, `afterSwap` and both swap return deltas. The
    /// pool manager rejects any key whose parameters claim a different set.
    uint16 public constant BITMAP = (uint16(1) << HOOKS_BEFORE_INITIALIZE_OFFSET)
        | (uint16(1) << HOOKS_BEFORE_SWAP_OFFSET) | (uint16(1) << HOOKS_AFTER_SWAP_OFFSET)
        | (uint16(1) << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET) | (uint16(1) << HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET);

    // -------------------------------------------------------------------------------------
    // `LaunchpadCore` storage layout: the same words `InfinitySettler._readLaunchSplit` reads,
    // for the same reason. `creator` and `creatorFeeShareBps` live in the core's internal
    // `launches` mapping and are reachable only through `extsload`.
    // -------------------------------------------------------------------------------------

    /// @dev Slot of `mapping(uint256 => Launch) launches` in `LaunchpadCore`.
    uint256 internal constant LAUNCHES_SLOT = 12;
    /// @dev word 0: `state` (uint8) then `creator` (address), packed.
    uint256 internal constant WORD_STATE_CREATOR = 0;
    /// @dev word 7: `settler`.
    uint256 internal constant WORD_SETTLER = 7;
    /// @dev word 21: `tradeFeeBps` (uint16), `creatorFeeShareBps` (uint16), `curveId` (uint16).
    uint256 internal constant WORD_FEE_BPS = 21;

    /// @dev Transient: set only while this contract holds a vault lock it opened itself.
    uint256 private constant LOCK_OPEN_SLOT = 0x656ba7d73bf378505610fcb465fe330597ea8dd6097878b5dec0341429a3ab50;

    /// @dev One word per pool, so the swap path reads one slot.
    struct PoolConfig {
        uint64 launchId;
        uint16 creatorBps;
        bool quoteIsCurrency0;
        bool registered;
    }

    ILaunchpadCore public immutable CORE;
    ICLPoolManager public immutable POOL_MANAGER;
    IVault public immutable VAULT;

    /// @notice Who may create a pool keyed to this hook.
    mapping(address initializer => bool allowed) public isInitializer;

    /// @notice Where `harvest` pays the treasury's share. Owner-settable, like
    /// `PositionLocker.launchpadTreasury`.
    address public treasury;

    mapping(PoolId poolId => PoolConfig) internal _pools;

    /// @notice The pool a launch graduated into through this hook; zero if none.
    mapping(uint256 launchId => PoolId) public launchPool;
    /// @notice The currency a launch's creator credit is kept in.
    mapping(uint256 launchId => Currency) public launchQuote;
    /// @notice What `claimCreator(launchId)` would pay right now, in `launchQuote(launchId)`.
    mapping(uint256 launchId => uint256) public creatorOwed;
    /// @notice What the next `harvest(quote)` sends to `treasury`.
    mapping(Currency quote => uint256) public treasuryOwed;

    error ZeroAddress();
    error InvalidTreasury(address treasury);
    error NotPoolManager();
    error NotAnInitializer(address sender);
    error LpFeeMustBeZero(uint24 fee);
    error NotALaunchPair(Currency currency0, Currency currency1);
    error LaunchAlreadyBound(uint256 launchId);
    error LaunchIdTooLarge(uint256 launchId);
    error LayoutMismatch(bytes32 word);
    error UnknownPool(PoolId poolId);
    error UnknownLaunch(uint256 launchId);
    error NotCreator(address caller, address creator);
    error NothingToClaim(uint256 launchId);
    error NothingToHarvest(Currency quote);
    error UnexpectedLock();

    event PoolRegistered(PoolId indexed poolId, uint256 indexed launchId, Currency quote, uint16 creatorBps);
    event FeeTaken(PoolId indexed poolId, uint256 indexed launchId, Currency quote, uint256 fee);
    event CreatorClaimed(uint256 indexed launchId, address indexed creator, Currency quote, uint256 amount);
    event Harvested(Currency indexed quote, address indexed treasury, uint256 amount, bool notified);
    event InitializerUpdated(address indexed initializer, bool allowed);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event Swept(Currency indexed currency, address indexed to, uint256 amount);

    /// @param _core The launchpad core whose launches graduate into pools keyed to this hook.
    /// @param _poolManager The CL pool manager; the vault is read from it, never passed.
    /// @param _owner The timelock.
    /// @param _initializer The settler, the one address that creates graduation pools.
    /// @param _treasury Where `harvest` pays. Born pointing at the burn sink's address, so the
    /// feed is right from the first graduation even if the sink is deployed later.
    constructor(
        ILaunchpadCore _core,
        ICLPoolManager _poolManager,
        address _owner,
        address _initializer,
        address _treasury
    ) Ownable(_owner) {
        if (address(_core) == address(0) || address(_poolManager) == address(0) || _initializer == address(0)) {
            revert ZeroAddress();
        }
        if (_treasury == address(0)) revert InvalidTreasury(_treasury);
        CORE = _core;
        POOL_MANAGER = _poolManager;
        VAULT = IProtocolFees(address(_poolManager)).vault();

        isInitializer[_initializer] = true;
        emit InitializerUpdated(_initializer, true);
        treasury = _treasury;
        emit TreasuryUpdated(address(0), _treasury);
    }

    /// @inheritdoc IHooks
    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return BITMAP;
    }

    // -------------------------------------------------------------------------------------
    // Pool creation
    // -------------------------------------------------------------------------------------

    /// @notice Bind a new pool to the launch that is graduating into it, or refuse it.
    /// @param sender `msg.sender` of `CLPoolManager.initialize`: the settler, which is why a
    /// settler must call the pool manager directly and never through the position manager.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external returns (bytes4) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        if (!isInitializer[sender]) revert NotAnInitializer(sender);
        // The hook carries the whole fee. A pool with an LP fee as well would charge twice, so a
        // settler misconfigured to a non-zero tier fails its graduation instead.
        if (key.fee != 0) revert LpFeeMustBeZero(key.fee);

        (uint256 launchId, bool quoteIsCurrency0) = _resolveLaunch(key.currency0, key.currency1);
        if (PoolId.unwrap(launchPool[launchId]) != bytes32(0)) revert LaunchAlreadyBound(launchId);
        if (launchId > type(uint64).max) revert LaunchIdTooLarge(launchId);
        uint16 creatorBps = _readCreatorBps(launchId, sender);

        PoolId poolId = key.toId();
        Currency quote = quoteIsCurrency0 ? key.currency0 : key.currency1;
        _pools[poolId] = PoolConfig({
            launchId: uint64(launchId), creatorBps: creatorBps, quoteIsCurrency0: quoteIsCurrency0, registered: true
        });
        launchPool[launchId] = poolId;
        launchQuote[launchId] = quote;
        emit PoolRegistered(poolId, launchId, quote, creatorBps);
        return ICLHooks.beforeInitialize.selector;
    }

    // -------------------------------------------------------------------------------------
    // The swap path
    // -------------------------------------------------------------------------------------

    /// @notice Take the fee when the quote is the specified currency: a buy with exact input, or a
    /// sell with exact output. The returned specified delta moves the amount the pool swaps.
    function beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (PoolId poolId, PoolConfig memory pool) = _pool(key);
        bool exactInput = params.amountSpecified < 0;
        // The specified currency is the input of an exact-input swap and the output of an
        // exact-output one, and `zeroForOne` says which of those is currency0.
        if ((exactInput == params.zeroForOne) != pool.quoteIsCurrency0) {
            return (ICLHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Exact input: the trader's whole payment, gross. Exact output: what they asked to
        // receive, net of the fee the pool now has to pay out on top.
        // forge-lint: disable-next-line(unsafe-typecast) - each branch casts a value its sign test made non-negative.
        uint256 amount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = _feeOn(amount, exactInput);
        if (fee != 0) _accrue(key, poolId, pool, fee);
        return (ICLHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @notice Take the fee when the quote is the unspecified currency: a buy with exact output,
    /// or a sell with exact input. The returned delta is charged to, or withheld from, the trader.
    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external returns (bytes4, int128) {
        (PoolId poolId, PoolConfig memory pool) = _pool(key);
        bool exactInput = params.amountSpecified < 0;
        if ((exactInput == params.zeroForOne) == pool.quoteIsCurrency0) return (ICLHooks.afterSwap.selector, 0);

        // `delta` is the pool's own swap, from the caller's side. Exact input: the quote the pool
        // pays out, gross of the fee. Exact output: the quote it took in, net of the fee the
        // trader now pays on top.
        int128 quoteDelta = pool.quoteIsCurrency0 ? delta.amount0() : delta.amount1();
        // forge-lint: disable-next-line(unsafe-typecast) - magnitude of a delta whose sign is tested first.
        uint256 amount = quoteDelta < 0 ? uint256(-int256(quoteDelta)) : uint256(int256(quoteDelta));
        uint256 fee = _feeOn(amount, exactInput);
        if (fee != 0) _accrue(key, poolId, pool, fee);
        return (ICLHooks.afterSwap.selector, fee.toInt128());
    }

    // -------------------------------------------------------------------------------------
    // Payouts
    // -------------------------------------------------------------------------------------

    /// @notice Pay a launch's creator everything credited to it, in the launch's quote asset.
    /// @dev Only the launch's CURRENT creator may call this, and it pays the caller. Same rule as
    /// the core's `claimCreatorFees`, so both pots behave alike, and a handoff through the core's
    /// `transferCreator` / `acceptCreator` moves this credit with the role.
    function claimCreator(uint256 launchId) external returns (uint256 amount) {
        if (PoolId.unwrap(launchPool[launchId]) == bytes32(0)) revert UnknownLaunch(launchId);
        address creator = creatorOf(launchId);
        if (msg.sender != creator) revert NotCreator(msg.sender, creator);

        amount = creatorOwed[launchId];
        if (amount == 0) revert NothingToClaim(launchId);
        creatorOwed[launchId] = 0;

        Currency quote = launchQuote[launchId];
        _payOut(quote, creator, amount);
        emit CreatorClaimed(launchId, creator, quote, amount);
    }

    /// @notice Pay the treasury its whole credit in `quote`, from every pool at once, then tell it.
    /// @dev Permissionless: the destination is fixed, so a caller chooses only when. Delivers
    /// first and notifies second, as `ChoiceFeeController.harvest` does, and the notification
    /// cannot undo the delivery - a sink that reverts keeps the tokens for its next buyback.
    ///
    /// 🔴 The code check is load-bearing, not tidiness. Solidity checks that a call target has
    /// code BEFORE the call, outside the `try`, so notifying a codeless address would revert the
    /// whole harvest. A treasury born pointing at a sink's reserved address has no code until the
    /// sink is deployed; until then a harvest simply delivers, and the sink spends that balance
    /// once it exists.
    function harvest(Currency quote) external returns (uint256 amount) {
        amount = treasuryOwed[quote];
        if (amount == 0) revert NothingToHarvest(quote);
        treasuryOwed[quote] = 0;

        address to = treasury;
        _payOut(quote, to, amount);

        bool notified;
        if (to.code.length != 0) {
            try IBurnSink(to).burn(quote, amount) {
                notified = true;
            } catch {}
        }
        emit Harvested(quote, to, amount, notified);
    }

    /// @inheritdoc ILockCallback
    /// @dev Gated on a lock this contract opened, not merely on the vault's identity - the same
    /// posture as `BuybackBurnSink.lockAcquired`.
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(VAULT) || !_lockOpen()) revert UnexpectedLock();
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        VAULT.burn(address(this), currency, amount);
        VAULT.take(currency, to, amount);
        return "";
    }

    // -------------------------------------------------------------------------------------
    // Owner
    // -------------------------------------------------------------------------------------

    /// @notice Add or remove an initializer. Pools already created are untouched: this list is
    /// consulted only when a pool is created.
    function setInitializer(address initializer, bool allowed) external onlyOwner {
        if (initializer == address(0)) revert ZeroAddress();
        isInitializer[initializer] = allowed;
        emit InitializerUpdated(initializer, allowed);
    }

    /// @notice Point `harvest` somewhere else. Credit already accrued goes to the new address.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0) || newTreasury == address(this)) revert InvalidTreasury(newTreasury);
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Recover a token sent to this contract by mistake.
    /// @dev Takes the whole balance, because this contract never holds a token of its own: fees
    /// are vault claims and every payout goes from the vault straight to its recipient.
    function sweep(Currency currency, address to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = currency.balanceOfSelf();
        if (amount != 0) currency.transfer(to, amount);
        emit Swept(currency, to, amount);
    }

    // -------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------

    /// @notice What a pool was bound to when it was created. `registered` is false for a pool
    /// this hook never saw.
    function poolInfo(PoolId poolId)
        external
        view
        returns (bool registered, uint256 launchId, Currency quote, uint16 creatorBps)
    {
        PoolConfig memory pool = _pools[poolId];
        if (!pool.registered) return (false, 0, Currency.wrap(address(0)), 0);
        return (true, pool.launchId, launchQuote[pool.launchId], pool.creatorBps);
    }

    /// @notice Who may call `claimCreator(launchId)` right now, and so who it pays: the launch's
    /// current creator, read off the core. Reverts `LayoutMismatch` unless the core reports the
    /// launch `Graduated` with a creator, which is the canary for a core laid out differently.
    function creatorOf(uint256 launchId) public view returns (address creator) {
        bytes32 stateAndCreator = _word(launchId, WORD_STATE_CREATOR);
        creator = address(uint160(uint256(stateAndCreator) >> 8));
        if (uint8(uint256(stateAndCreator)) != uint8(ILaunchpadCore.LaunchState.Graduated) || creator == address(0)) {
            revert LayoutMismatch(stateAndCreator);
        }
    }

    // -------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------

    function _pool(PoolKey calldata key) private view returns (PoolId poolId, PoolConfig memory pool) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        poolId = key.toId();
        pool = _pools[poolId];
        // Unreachable for a pool the manager holds - `beforeInitialize` either registers a pool
        // or reverts its creation - so this is a canary, not a policy.
        if (!pool.registered) revert UnknownPool(poolId);
    }

    /// @dev 1% of a gross amount, or the 1/99 of a net amount that is the same 1% of its gross.
    function _feeOn(uint256 amount, bool amountIsGross) private pure returns (uint256) {
        return amountIsGross ? amount * FEE_PIPS / PIPS_DENOMINATOR : amount * FEE_PIPS / (PIPS_DENOMINATOR - FEE_PIPS);
    }

    function _accrue(PoolKey calldata key, PoolId poolId, PoolConfig memory pool, uint256 fee) private {
        Currency quote = pool.quoteIsCurrency0 ? key.currency0 : key.currency1;
        uint256 toCreator = fee * pool.creatorBps / BPS_DENOMINATOR;
        creatorOwed[pool.launchId] += toCreator;
        treasuryOwed[quote] += fee - toCreator;
        VAULT.mint(address(this), quote, fee);
        emit FeeTaken(poolId, pool.launchId, quote, fee);
    }

    /// @dev The launch token is the currency the core recognises; the other has to be that
    /// launch's pair asset. Tried from currency0 so the answer does not depend on call order.
    function _resolveLaunch(Currency currency0, Currency currency1)
        private
        view
        returns (uint256 launchId, bool quoteIsCurrency0)
    {
        (bool found0, uint256 id0) = _launchOf(Currency.unwrap(currency0));
        if (found0 && address(CORE.getLaunchPairAsset(id0)) == Currency.unwrap(currency1)) return (id0, false);
        (bool found1, uint256 id1) = _launchOf(Currency.unwrap(currency1));
        if (found1 && address(CORE.getLaunchPairAsset(id1)) == Currency.unwrap(currency0)) return (id1, true);
        revert NotALaunchPair(currency0, currency1);
    }

    function _launchOf(address token) private view returns (bool found, uint256 launchId) {
        try CORE.getLaunchByToken(token) returns (uint256 id) {
            return (true, id);
        } catch {
            return (false, 0);
        }
    }

    /// @dev `InfinitySettler._readLaunchSplit`'s three canaries, with `sender` in place of the
    /// settler's own address: the launch is mid-graduation, through the settler creating this
    /// pool, and its creator share is a legal bps.
    function _readCreatorBps(uint256 launchId, address sender) private view returns (uint16 creatorBps) {
        bytes32 stateAndCreator = _word(launchId, WORD_STATE_CREATOR);
        if (uint8(uint256(stateAndCreator)) != uint8(ILaunchpadCore.LaunchState.PendingSettlement)) {
            revert LayoutMismatch(stateAndCreator);
        }
        bytes32 settlerWord = _word(launchId, WORD_SETTLER);
        if (address(uint160(uint256(settlerWord))) != sender) revert LayoutMismatch(settlerWord);
        bytes32 feeWord = _word(launchId, WORD_FEE_BPS);
        creatorBps = uint16(uint256(feeWord) >> 16);
        if (creatorBps > BPS_DENOMINATOR) revert LayoutMismatch(feeWord);
    }

    function _word(uint256 launchId, uint256 offset) private view returns (bytes32) {
        bytes32 base = keccak256(abi.encode(launchId, LAUNCHES_SLOT));
        return CORE.extsload(bytes32(uint256(base) + offset), 1)[0];
    }

    function _payOut(Currency currency, address to, uint256 amount) private {
        _setLockOpen(true);
        VAULT.lock(abi.encode(currency, to, amount));
        _setLockOpen(false);
    }

    function _setLockOpen(bool open) private {
        assembly ("memory-safe") {
            tstore(LOCK_OPEN_SLOT, open)
        }
    }

    function _lockOpen() private view returns (bool open) {
        assembly ("memory-safe") {
            open := tload(LOCK_OPEN_SLOT)
        }
    }
}
