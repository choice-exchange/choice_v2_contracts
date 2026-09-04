// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

/// @title ChoiceRouter
/// @notice Executes ONE swap route that spans two Infinity deployments - Choice and Pumex -
/// under a single end-to-end `minimumReceive` (plan M5.4).
///
/// **This contract exists for exactly one reason.** `ImmutableState` holds
/// `IVault public immutable vault`, so a UniversalRouter can only ever lock the vault it was
/// constructed with, and `EXECUTE_SUB_PLAN` recurses on the same router. Two Infinity
/// deployments therefore mean two lock sessions, and nothing can hold the intermediate token
/// between them. Per-leg minimums are NOT a substitute: route A->B on Choice with `minOut_B`
/// and B->C on Pumex with `minOut_C`, and an adversary can push both legs to exactly their
/// minimums while the realised A->C lands far under quote. Only a route-level check on what
/// the user actually receives closes that, and enforcing it across two vaults needs a contract
/// that holds the intermediate.
///
/// **Routes inside ONE deployment must NOT come here.** `INFI_SWAP` already runs a whole
/// split, multi-hop route in a single vault lock, netting every intermediate as a delta. This
/// router is strictly worse for that case - it materialises intermediates as real ERC20
/// transfers - so `execute` REVERTS unless the route actually spans two distinct vaults.
/// Single-deployment routes go straight to the UniversalRouter: no extra hop, no extra gas,
/// no new trust.
///
/// **We lock the vaults ourselves rather than calling Pumex's UniversalRouter.** Measured on
/// mainnet 2026-09-05: Pumex's UniversalRouter `0xbc291687...` is `Ownable` + `Pausable`, its
/// `execute` is `whenNotPaused`, and its owner is a 3-of-6 Gnosis Safe. Routing through it
/// would hand three signers outside Choice a kill switch over every cross-venue route. A
/// vault's `lock` is permissionless, so we take it directly - the pattern already runs in
/// production in Choice's own `InjEvmArbRouted`. This is why the contract carries a
/// swap/settle/take loop at all; the M5 plan's "orchestrates the two UniversalRouters" wording
/// predates that measurement.
///
/// **Vaults are allowlisted, and that is the whole trust boundary.** Hops name their own
/// `PoolKey.poolManager`, but a pool manager cannot move value on its own: deltas only exist
/// in the vault's ledger, and `accountAppBalanceDelta` is refused for an app the vault has not
/// registered. So a forged manager can return any `BalanceDelta` it likes and still credit
/// nothing - which is also why every amount below is read back from `vault.currencyDelta`
/// rather than trusted from the swap's return value. Upstream warns that a hook with
/// `BEFORE_SWAP_RETURNS_DELTA` or `AFTER_SWAP_RETURNS_DELTA` may alter swap amounts, and Pumex
/// pools carry hooks Choice does not control; reading the ledger makes that a non-event.
///
/// **No per-hop price limits, by design.** Every swap runs to the extreme sqrt-price bound, so
/// an individual hop may move a pool arbitrarily far. `minimumReceive` on the route's realised
/// output is the only guard, and it is the only one that is not gameable leg by leg.
///
/// Native INJ is not handled: wrap to wINJ before calling, exactly as the UniversalRouter path
/// already does.
contract ChoiceRouter is Ownable2Step, ReentrancyGuardTransient, ILockCallback {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice One swap against one pool.
    /// @param key the pool, including its own `poolManager` - Choice's or Pumex's
    /// @param zeroForOne direction; the input currency is `currency0` when true
    /// @param entryBps this hop's share of its STAGE's entry amount, in basis points. ZERO
    /// means "chain": consume the whole positive delta this lock already holds in the hop's
    /// input currency, which is how multi-hop legs inside one stage are expressed. Splits
    /// inside a stage are the non-zero case, and they are shares rather than absolute amounts
    /// because a later stage's entry amount is not knowable when the route is signed.
    /// @param hookData forwarded verbatim; empty for every pool Choice operates
    struct Hop {
        PoolKey key;
        bool zeroForOne;
        uint16 entryBps;
        bytes hookData;
    }

    /// @notice Every hop that shares one vault, executed inside one `lock`.
    struct Stage {
        IVault vault;
        Hop[] hops;
    }

    /// @param currencyIn what the caller pays, pulled through Permit2
    /// @param currencyOut what `recipient` receives
    /// @param amountIn exact input
    /// @param minimumReceive the ONE guard on this route, measured on realised output
    /// @param recipient who receives `currencyOut`; dust returns to `msg.sender`
    /// @param deadline unix seconds
    /// @param stages in execution order, spanning at least two distinct vaults
    struct RouteParams {
        Currency currencyIn;
        Currency currencyOut;
        uint256 amountIn;
        uint256 minimumReceive;
        address recipient;
        uint256 deadline;
        Stage[] stages;
    }

    /// @dev `keccak256("choice.v2.router.activeVault") - 1`. Transient: the gate below is only
    /// meaningful for the duration of one `lock`, and Cancun is available from genesis on both
    /// Injective networks.
    /// @dev Written as a literal because inline assembly cannot reference a computed
    /// constant. Reproduce with `cast keccak "choice.v2.router.activeVault"` and subtract one;
    /// `test_transientSlotMatchesItsDerivation` asserts it.
    uint256 private constant ACTIVE_VAULT_SLOT = 0xf6d74ac3105b1000971a93f4dbcb94238b3965db702346eeed7fa44221e4b5e9;

    uint16 private constant BPS = 10_000;

    IAllowanceTransfer public immutable PERMIT2;

    /// @notice Vaults this router will lock. The trust boundary; see the contract notice.
    mapping(address vault => bool allowed) public allowedVault;

    event VaultAllowed(address indexed vault, bool allowed);
    event Routed(
        address indexed sender,
        address indexed recipient,
        Currency indexed currencyOut,
        uint256 amountIn,
        uint256 amountOut
    );

    error DeadlinePassed();
    error NotCrossVault();
    error VaultNotAllowed(address vault);
    error NotVault();
    error EmptyStage(uint256 stageIndex);
    error NothingToChain(uint256 stageIndex, uint256 hopIndex);
    error StageEntryEmpty(uint256 stageIndex);
    error InsufficientOutput(uint256 got, uint256 want);

    constructor(address _owner, IAllowanceTransfer _permit2, IVault[] memory _vaults) Ownable(_owner) {
        PERMIT2 = _permit2;
        for (uint256 i; i < _vaults.length; ++i) {
            allowedVault[address(_vaults[i])] = true;
            emit VaultAllowed(address(_vaults[i]), true);
        }
    }

    // ── governance ────────────────────────────────────────────────────────

    /// @notice Add or drop a vault. Pumex could redeploy, and Choice will have more than one
    /// deployment eventually; neither should need a new router.
    function setVault(IVault vault, bool allowed) external onlyOwner {
        allowedVault[address(vault)] = allowed;
        emit VaultAllowed(address(vault), allowed);
    }

    // ── routing ───────────────────────────────────────────────────────────

    /// @notice Run `p` and send `currencyOut` to `p.recipient`.
    /// @dev The caller must have approved this router as a Permit2 spender for `currencyIn`.
    /// @return amountOut what the route actually produced, which is what the guard checked
    function execute(RouteParams calldata p) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > p.deadline) revert DeadlinePassed();
        _requireCrossVault(p);

        // Snapshotted BEFORE the pull, so every figure below is what THIS route moved. A
        // balance the router already held - a stray donation, a previous sweep that failed -
        // is invisible to the accounting and cannot be spent or swept by a caller.
        uint256 stageCount = p.stages.length;
        uint256[] memory stageBefore = new uint256[](stageCount);
        for (uint256 i; i < stageCount; ++i) {
            stageBefore[i] = _stageIn(p.stages[i], i).balanceOfSelf();
        }
        Currency[] memory touched = _touched(p);
        uint256[] memory touchedBefore = new uint256[](touched.length);
        for (uint256 i; i < touched.length; ++i) {
            touchedBefore[i] = touched[i].balanceOfSelf();
        }

        PERMIT2.transferFrom(msg.sender, address(this), p.amountIn.toUint160(), Currency.unwrap(p.currencyIn));

        for (uint256 i; i < stageCount; ++i) {
            // Stage 0 resolves to exactly `amountIn`. A later stage takes whatever the route
            // has produced in its input currency and not yet spent - which is the intermediate
            // for a handoff, and the unspent remainder for a split that crosses the boundary.
            uint256 entry = _stageIn(p.stages[i], i).balanceOfSelf() - stageBefore[i];
            if (entry == 0) revert StageEntryEmpty(i);
            _runStage(p.stages[i], entry, i);
        }

        amountOut = _payOut(p, touched, touchedBefore);
        emit Routed(msg.sender, p.recipient, p.currencyOut, p.amountIn, amountOut);
    }

    /// @inheritdoc ILockCallback
    /// @dev Gated on the lock IN PROGRESS, not merely on a known vault. Both allowlisted
    /// vaults can call this at any time; without the transient check one of them could invoke
    /// it outside a route, when the decoded stage would be attacker-chosen.
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != _activeVault()) revert NotVault();
        (Stage memory stage, uint256 entry, uint256 stageIndex) = abi.decode(data, (Stage, uint256, uint256));

        _swapHops(stage, entry, stageIndex);
        _settleStage(stage);
        return "";
    }

    // ── internals ─────────────────────────────────────────────────────────

    function _runStage(Stage calldata stage, uint256 entry, uint256 stageIndex) private {
        address vault = address(stage.vault);
        if (!allowedVault[vault]) revert VaultNotAllowed(vault);

        _setActiveVault(vault);
        stage.vault.lock(abi.encode(stage, entry, stageIndex));
        // Cleared before anything else can run, so a stage that reverts cannot leave the
        // callback gate open for the rest of the transaction.
        _setActiveVault(address(0));
    }

    function _swapHops(Stage memory stage, uint256 entry, uint256 stageIndex) private {
        uint256 hopCount = stage.hops.length;
        for (uint256 i; i < hopCount; ++i) {
            Hop memory hop = stage.hops[i];
            Currency inCurrency = hop.zeroForOne ? hop.key.currency0 : hop.key.currency1;

            uint256 amountIn;
            if (hop.entryBps == 0) {
                int256 delta = stage.vault.currencyDelta(address(this), inCurrency);
                if (delta <= 0) revert NothingToChain(stageIndex, i);
                // forge-lint: disable-next-line(unsafe-typecast) - guarded positive above.
                amountIn = uint256(delta);
            } else {
                amountIn = (entry * hop.entryBps) / BPS;
            }

            ICLPoolManager(address(hop.key.poolManager))
                .swap(
                    hop.key,
                    ICLPoolManager.SwapParams({
                        zeroForOne: hop.zeroForOne,
                        // Negative amountSpecified is exact-input.
                        amountSpecified: -amountIn.toInt256(),
                        sqrtPriceLimitX96: hop.zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
                    }),
                    hop.hookData
                );
        }
    }

    /// @dev Debts first, then credits: the vault pays a credit out of real reserves, so taking
    /// before settling can fail on a vault that is exactly funded.
    function _settleStage(Stage memory stage) private {
        Currency[] memory currencies = _stageCurrencies(stage);

        for (uint256 i; i < currencies.length; ++i) {
            int256 delta = stage.vault.currencyDelta(address(this), currencies[i]);
            if (delta >= 0) continue;
            // forge-lint: disable-next-line(unsafe-typecast) - magnitude of a known negative.
            uint256 owed = uint256(-delta);
            stage.vault.sync(currencies[i]);
            IERC20(Currency.unwrap(currencies[i])).safeTransfer(address(stage.vault), owed);
            stage.vault.settle();
        }
        for (uint256 i; i < currencies.length; ++i) {
            int256 delta = stage.vault.currencyDelta(address(this), currencies[i]);
            if (delta <= 0) continue;
            // forge-lint: disable-next-line(unsafe-typecast) - guarded positive above.
            stage.vault.take(currencies[i], address(this), uint256(delta));
        }
    }

    /// @dev Sends the output to `recipient` and returns everything else this route produced -
    /// unspent input, intermediate rounding - to `msg.sender`.
    function _payOut(RouteParams calldata p, Currency[] memory touched, uint256[] memory before)
        private
        returns (uint256 amountOut)
    {
        amountOut = p.currencyOut.balanceOfSelf();
        for (uint256 i; i < touched.length; ++i) {
            if (touched[i] == p.currencyOut) {
                amountOut -= before[i];
                break;
            }
        }
        if (amountOut < p.minimumReceive) revert InsufficientOutput(amountOut, p.minimumReceive);
        p.currencyOut.transfer(p.recipient, amountOut);

        for (uint256 i; i < touched.length; ++i) {
            if (touched[i] == p.currencyOut) continue;
            uint256 dust = touched[i].balanceOfSelf() - before[i];
            if (dust != 0) touched[i].transfer(msg.sender, dust);
        }
    }

    /// @dev The guard that keeps single-deployment routes on the UniversalRouter.
    function _requireCrossVault(RouteParams calldata p) private pure {
        uint256 stageCount = p.stages.length;
        if (stageCount < 2) revert NotCrossVault();
        IVault first = p.stages[0].vault;
        for (uint256 i = 1; i < stageCount; ++i) {
            if (p.stages[i].vault != first) return;
        }
        revert NotCrossVault();
    }

    function _stageIn(Stage calldata stage, uint256 stageIndex) private pure returns (Currency) {
        if (stage.hops.length == 0) revert EmptyStage(stageIndex);
        Hop calldata first = stage.hops[0];
        return first.zeroForOne ? first.key.currency0 : first.key.currency1;
    }

    /// @dev Every currency the route can move, deduplicated: both sides of every pool, plus
    /// the declared endpoints in case a route is built so that one of them never appears in a
    /// key (it cannot today, but the accounting should not depend on that).
    function _touched(RouteParams calldata p) private pure returns (Currency[] memory out) {
        uint256 bound = 2;
        for (uint256 i; i < p.stages.length; ++i) {
            bound += p.stages[i].hops.length * 2;
        }
        out = new Currency[](bound);
        uint256 n;
        n = _push(out, n, p.currencyIn);
        n = _push(out, n, p.currencyOut);
        for (uint256 i; i < p.stages.length; ++i) {
            Hop[] calldata hops = p.stages[i].hops;
            for (uint256 j; j < hops.length; ++j) {
                n = _push(out, n, hops[j].key.currency0);
                n = _push(out, n, hops[j].key.currency1);
            }
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _stageCurrencies(Stage memory stage) private pure returns (Currency[] memory out) {
        out = new Currency[](stage.hops.length * 2);
        uint256 n;
        for (uint256 i; i < stage.hops.length; ++i) {
            n = _push(out, n, stage.hops[i].key.currency0);
            n = _push(out, n, stage.hops[i].key.currency1);
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _push(Currency[] memory list, uint256 n, Currency c) private pure returns (uint256) {
        for (uint256 i; i < n; ++i) {
            if (list[i] == c) return n;
        }
        list[n] = c;
        return n + 1;
    }

    function _setActiveVault(address vault) private {
        assembly ("memory-safe") {
            tstore(ACTIVE_VAULT_SLOT, vault)
        }
    }

    function _activeVault() private view returns (address vault) {
        assembly ("memory-safe") {
            vault := tload(ACTIVE_VAULT_SLOT)
        }
    }
}
