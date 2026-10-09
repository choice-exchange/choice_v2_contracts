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
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";

import {IChoiceAdapter} from "../interfaces/IChoiceAdapter.sol";
import {IHelixSwap} from "../interfaces/IHelixSwap.sol";
import {ISolidlyPair} from "../interfaces/ISolidlyPair.sol";

/// @title ChoiceAggregator
/// @notice Executes ONE exact-input swap route across every kind of liquidity Injective EVM has -
/// Infinity vaults (Choice's and Pumex's, CL and Bin), Solidly pairs (Pumex V2), the Helix
/// orderbook through the `0x68` swap precompile, and any venue an `IChoiceAdapter` wraps - under a
/// single end-to-end `minimumReceive`.
///
/// **1.1.0** adds the `Adapter` step, an optional fee on the output (`feeBps` / `feeRecipient`)
/// and `executeWithPermit`. Everything 1.0.0 did, it does the same way.
///
/// **Why it exists.** Measured on mainnet 2026-10-07, the deepest INJ/USD liquidity on Injective
/// EVM sat in three places no Choice router could reach: the Helix INJ/USDC book, Pumex's Infinity
/// CL pools, and Pumex's V2 wINJ/USDT pair - the only INJ/USDT pool of any depth on the EVM.
/// `ChoiceRouter` reaches the second only as part of a route that also touches Choice's vault
/// (`NotCrossVault`), and swaps CL pools only. This contract is the general executor;
/// `ChoiceRouter` stays as it is.
///
/// **A route is an ordered list of steps.** Each step spends `shareBps` of what the ROUTE
/// currently holds of its `tokenIn` and produces `tokenOut`. Share-of-what-is-held rather than an
/// absolute amount, because a later step's input is not knowable when the route is signed: a
/// split is two steps on the same token (`6000`, then `10_000` of what is left), a handoff is a
/// step on the previous step's output, and two branches that land on the same token simply merge.
/// The last step on a token takes everything, so a split leaves no rounding behind.
///
/// **What the route holds is a delta, never a balance.** Every currency the route can touch is
/// snapshotted before the input is pulled, and only the excess over that snapshot is spendable,
/// payable or refundable. A balance the contract already held - a donation, a stray send - is
/// invisible to every route, and a step that spent into it makes the payout's subtraction fail
/// (`RouteOverspent`) rather than quietly paying with someone else's money.
///
/// **The guard is on what the user receives, and only there.** Per-step minimums are not a
/// substitute (an adversary can push every step to exactly its own floor while the realised
/// end-to-end price lands far under quote), so every step runs unguarded and `minimumReceive` is
/// checked on the realised output. 🔴 A route signed with `minimumReceive == 0` therefore has no
/// guard at all - the frontend must refuse one; the contract does not, because a floor expressed
/// in output units is a quote, and quoting is not this contract's job.
///
/// **An optional fee on the output.** `feeBps` of what the route realised in `currencyOut` goes to
/// `feeRecipient`, and `minimumReceive` is checked on what is left - which is exactly what
/// `recipient` receives. The fee is set by whoever builds the route, so which routes carry one
/// (a venue's legs, an integrator's flow) is a planner's policy. It is not keyed on venues here
/// because a fee the contract imposed per venue would bind only callers who chose this contract
/// anyway: those venues can be traded directly. What the contract guarantees is the ceiling -
/// no route charges more than `MAX_FEE_BPS` - and a frontend checks the rate and the recipient
/// against what it showed the user, as it checks the minimum.
///
/// **Trust, per kind:**
///
/// - *Infinity vaults are allowlisted, and that is the whole trust boundary for that kind.* A
///   vault's ledger decides what `_settleStage` pays, so a foreign vault is a decision about that
///   deployment's governance (see `ChoiceRouter`'s notice, audit R-2: a vault owner can
///   `registerApp` a contract that assigns this router a debt mid-stage; `minimumReceive` is what
///   bounds it). The callback is bound to the exact payload handed to `lock`, single-use per lock.
///   ⚠️ `minimumReceive` bounds the OUTPUT only. What a route hands back as dust - an unfilled
///   Helix remainder, an unspent share - has no floor, so a hostile app on an allowlisted vault,
///   reached through a hook in the route, could take it. Ordinary hooks cannot: a hook that takes
///   more than its hop's output leaves the step `StepPaidNothing`.
/// - *Solidly pairs are NOT allowlisted, deliberately.* A pair is paid exactly the step's input by
///   `transfer` and is never approved for anything, so the most a hostile pair can take is the one
///   step's input; it cannot produce `tokenOut` it does not have, and a step that produced none
///   reverts. A new Pumex pair needs no governance batch to become routable.
/// - *Adapters are NOT allowlisted either, for the same reason.* An adapter is paid exactly the
///   step's input by `transfer`, is never approved, and is called with THIS contract as the
///   recipient. Whatever code runs inside it holds no allowance from here, cannot re-enter
///   `execute`, and is not a vault `lockAcquired` will answer - so of what this contract holds
///   it can take that one step's input and nothing else, and a step that produced none of its
///   `tokenOut` reverts. Its return value is decoded but never trusted; output is the balance
///   delta, as for every kind. ⚠️ Like any venue code that runs mid-route - a hostile Solidly
///   pair included - it can also MOVE PRICES a later step trades against, since steps run
///   unguarded; `minimumReceive` is what bounds that, as it bounds every other way a route can
///   underdeliver. So a planner lists only adapters it has read, and a frontend that does not
///   trust its planner checks the adapter addresses too.
/// - *The Helix precompile is a fixed address*, and its markets are allowlisted by the CHAIN
///   (`swap_params.allowed_markets`), not here.
///
/// **Inside a route, native INJ is `address(0)`, wINJ is an ERC20, and the two are never
/// conflated.** Infinity and Solidly pools on Injective trade wINJ; the Helix precompile takes and
/// pays NATIVE INJ and refuses wINJ. The route says which one each step spends, and `Wrap` /
/// `Unwrap` steps convert explicitly. Native output is sent with a plain call.
///
/// **At the INPUT, INJ is one currency.** A wallet holding some of each spends both: any part of
/// an INJ `amountIn` may arrive as `msg.value` and the rest is pulled as wINJ, then converted to
/// the form `currencyIn` names. The calldata does not depend on the mix, so the caller picks
/// `msg.value` from its own balances without asking for a new route.
///
/// 🔴 **Two precompile behaviours the accounting is built around:** a Helix fill is floored to the
/// market's quantity tick, and a swap larger than the book fills PARTIALLY without reverting.
/// Either way the unspent input stays here as route money - the next step on that token spends
/// it, or it is refunded to the caller with the rest of the dust - and the output shortfall is
/// what `minimumReceive` catches.
///
/// 🔴 **And two it does not absorb.** Below the market's minimum notional (measured: $1 on
/// INJ/USDC and USDC/USDT) or under one quantity tick, the precompile REVERTS, and so does the
/// whole route. And a step whose input comes out empty reverts `StepInputEmpty` rather than being
/// skipped - so a "fill the book, send the leftover to an AMM" route reverts whenever the book takes
/// everything. A planner must keep every Helix leg above the market's minimums and never emit a
/// step whose input can be zero; the backend's does both, because the precompile's QUOTE refuses
/// the same sizes its swap does.
contract ChoiceAggregator is Ownable2Step, ReentrancyGuardTransient, ILockCallback {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    enum Kind {
        /// native INJ -> wINJ, through `WINJ.deposit`
        Wrap,
        /// wINJ -> native INJ, through `WINJ.withdraw`
        Unwrap,
        /// one lock on an allowlisted Infinity vault; `data` = `abi.encode(InfinityStage)`
        Infinity,
        /// one swap through a Solidly pair; `data` = `abi.encode(address pair, bool zeroForOne)`
        Solidly,
        /// one swap through the `0x68` precompile; `data` = `abi.encode(string marketId)`
        Helix,
        /// one swap through an `IChoiceAdapter`; `data` = `abi.encode(address adapter, bytes
        /// adapterData)`, `adapterData` passed through verbatim
        Adapter
    }

    /// @param tokenIn what the step spends; `address(0)` is native INJ
    /// @param tokenOut what the step must produce; measured as a balance delta, and a step that
    /// produced none reverts `StepPaidNothing`
    /// @param shareBps of what the route holds of `tokenIn` when the step runs, 1..10_000
    struct Step {
        Kind kind;
        address tokenIn;
        address tokenOut;
        uint16 shareBps;
        bytes data;
    }

    /// @notice One swap against one Infinity pool.
    /// @param key the pool, including its own `poolManager` - which must belong to the stage's vault
    /// @param zeroForOne direction; for a Bin pool this is `swapForY`
    /// @param bin true for a Bin pool. Carried, never derived: a CL and a Bin key can be byte-equal
    /// except for `poolManager`, and both managers answer `getSlot0` on the same selector
    /// @param entryBps this hop's share of the STAGE's entry amount; ZERO chains, consuming the whole
    /// positive delta this lock already holds in the hop's input currency
    /// @param hookData forwarded verbatim
    struct Hop {
        PoolKey key;
        bool zeroForOne;
        bool bin;
        uint16 entryBps;
        bytes hookData;
    }

    /// @notice Every hop of one step, executed inside one `lock` of `vault`.
    struct InfinityStage {
        IVault vault;
        Hop[] hops;
    }

    /// @param currencyIn what the caller pays: Permit2 for an ERC20. INJ - `address(0)` or wINJ -
    /// may be paid in ANY mix of `msg.value` and wINJ through Permit2, and is converted into the
    /// form `currencyIn` names before the first step
    /// @param currencyOut what `recipient` receives; `address(0)` is native INJ
    /// @param amountIn exact input
    /// @param minimumReceive the ONE guard on this route, measured on what `recipient` receives -
    /// realised output less the fee
    /// @param recipient who receives `currencyOut`; dust returns to `msg.sender`
    /// @param deadline unix seconds; also handed to every Helix step
    /// @param feeBps of realised output, paid to `feeRecipient`; 0..`MAX_FEE_BPS`
    /// @param feeRecipient who receives the fee; set if and only if `feeBps` is
    /// @param steps in execution order
    struct RouteParams {
        address currencyIn;
        address currencyOut;
        uint256 amountIn;
        uint256 minimumReceive;
        address recipient;
        uint256 deadline;
        uint16 feeBps;
        address feeRecipient;
        Step[] steps;
    }

    /// @dev `keccak256("choice.v2.aggregator.activeVault") - 1`. Transient: the gate is only
    /// meaningful for the duration of one `lock`. Literal because inline assembly cannot reference
    /// a computed constant; `test_transientSlotsMatchTheirDerivation` asserts it.
    uint256 private constant ACTIVE_VAULT_SLOT = 0x521ef52308a276606f192773ee4e5066279c751ae60ace30d9dbdedbc40c6b7d;

    /// @dev `keccak256("choice.v2.aggregator.stagePayload") - 1`. Holds the hash of the exact bytes
    /// `_runInfinity` handed to `lock`, for the duration of that lock. See `ChoiceRouter`'s
    /// `STAGE_PAYLOAD_SLOT` for why authenticating the caller alone is not enough (audit R-1).
    uint256 private constant STAGE_PAYLOAD_SLOT = 0xbd74014f058beb366b185ec0ddc5288621cbbba0a9f626076702bc8a4fe16b2b;

    uint16 private constant BPS = 10_000;

    /// @notice The most any route may pay in fees: 1% of its realised output.
    uint16 public constant MAX_FEE_BPS = 100;

    string public constant VERSION = "1.1.0";

    address internal constant NATIVE = address(0);

    IHelixSwap public constant HELIX = IHelixSwap(0x0000000000000000000000000000000000000068);

    IAllowanceTransfer public immutable PERMIT2;

    /// @notice Wrapped INJ. Injective's is a bank-backed token at `0x0000000088827d2d…3FfB` with
    /// WETH9's `deposit` / `withdraw`.
    IWETH9 public immutable WINJ;

    /// @notice Infinity vaults this router will lock. The trust boundary for `Kind.Infinity`.
    mapping(address vault => bool allowed) public allowedVault;

    event VaultAllowed(address indexed vault, bool allowed);
    event Routed(
        address indexed sender,
        address indexed recipient,
        address indexed currencyOut,
        address currencyIn,
        uint256 amountIn,
        uint256 amountOut
    );
    /// @notice Emitted beside `Routed` when a route paid a fee; `Routed.amountOut` is net of it.
    event FeePaid(address indexed feeRecipient, address indexed currency, uint256 amount);

    error DeadlinePassed();
    error NoSteps();
    error ZeroAmount();
    error ZeroRecipient();
    error BadRecipient(address recipient);
    error SameCurrency();
    error ValueMismatch(uint256 sent, uint256 expected);
    error BadShare(uint256 stepIndex);
    error BadStep(uint256 stepIndex);
    error StepInputEmpty(uint256 stepIndex);
    error StepPaidNothing(uint256 stepIndex);
    error RouteOverspent(address currency);
    error InsufficientOutput(uint256 got, uint256 want);
    error NativeTransferFailed(address to);
    error NativeNotAccepted(address from);
    error VaultNotAllowed(address vault);
    error NotVault();
    error StagePayloadMismatch();
    error EmptyStage(uint256 stepIndex);
    error HopInputMismatch(uint256 stepIndex, uint256 hopIndex);
    error StageOverAllocated(uint256 stepIndex);
    error NothingToChain(uint256 stepIndex, uint256 hopIndex);
    error BadFee();

    constructor(address _owner, IAllowanceTransfer _permit2, IWETH9 _winj, IVault[] memory _vaults) Ownable(_owner) {
        PERMIT2 = _permit2;
        WINJ = _winj;
        for (uint256 i; i < _vaults.length; ++i) {
            allowedVault[address(_vaults[i])] = true;
            emit VaultAllowed(address(_vaults[i]), true);
        }
    }

    /// @notice Native INJ arrives here only from `WINJ.withdraw`, an allowlisted vault's `take`,
    /// or - if it ever pays by call rather than by bank credit - the Helix precompile. Anything
    /// else would be a donation no route can spend and no one can recover, so it is refused.
    receive() external payable {
        if (msg.sender != address(WINJ) && msg.sender != address(HELIX) && !allowedVault[msg.sender]) {
            revert NativeNotAccepted(msg.sender);
        }
    }

    // ── governance ────────────────────────────────────────────────────────

    /// @notice Add or drop an Infinity vault.
    function setVault(IVault vault, bool allowed) external onlyOwner {
        allowedVault[address(vault)] = allowed;
        emit VaultAllowed(address(vault), allowed);
    }

    // ── routing ───────────────────────────────────────────────────────────

    /// @notice Run `p` and send `currencyOut` to `p.recipient`.
    /// @dev For an ERC20 input the caller must have approved this contract as a Permit2 spender
    /// and send no value. For an INJ input (`address(0)` or wINJ) the caller sends any part of
    /// `amountIn` as `msg.value`, and the Permit2 approval covers the wINJ rest when there is one.
    /// @return amountOut what `recipient` received - the route's realised output less the fee -
    /// which is what the guard checked
    function execute(RouteParams calldata p) external payable nonReentrant returns (uint256 amountOut) {
        return _execute(p);
    }

    /// @notice `execute`, with a Permit2 allowance for this contract granted by signature in the
    /// same transaction - so a wallet's first route through this aggregator (or its first after an
    /// allowance expired) needs no separate approval transaction.
    /// @dev The permit is tried and its failure ignored. A signed permit is public once broadcast,
    /// and anyone may submit it to Permit2 first; the allowance then exists and only this call's
    /// copy fails. Whether the allowance is really there is decided by the pull, which reverts on
    /// its own terms if it is not.
    function executeWithPermit(
        RouteParams calldata p,
        IAllowanceTransfer.PermitSingle calldata permitSingle,
        bytes calldata signature
    ) external payable nonReentrant returns (uint256 amountOut) {
        try PERMIT2.permit(msg.sender, permitSingle, signature) {} catch {}
        return _execute(p);
    }

    function _execute(RouteParams calldata p) private returns (uint256 amountOut) {
        if (block.timestamp > p.deadline) revert DeadlinePassed();
        if (p.steps.length == 0) revert NoSteps();
        if (p.amountIn == 0) revert ZeroAmount();
        if (p.recipient == address(0)) revert ZeroRecipient();
        // Output sent here, or to wINJ (whose fallback would wrap a native payout back to THIS
        // contract), is stranded for good: nothing here can sweep it. The same holds for a fee.
        if (p.recipient == address(this) || p.recipient == address(WINJ)) revert BadRecipient(p.recipient);
        if (p.feeBps > MAX_FEE_BPS || (p.feeBps == 0) != (p.feeRecipient == address(0))) revert BadFee();
        if (p.feeRecipient == address(this) || p.feeRecipient == address(WINJ)) {
            revert BadRecipient(p.feeRecipient);
        }
        if (p.currencyIn == p.currencyOut) revert SameCurrency();

        // Snapshotted BEFORE the pull, so every figure below is what THIS route moved. Native
        // input is already in the balance by now, so it is taken back out of the snapshot.
        address[] memory touched = _touched(p);
        uint256[] memory before = new uint256[](touched.length);
        for (uint256 i; i < touched.length; ++i) {
            before[i] = _balance(touched[i]);
            if (touched[i] == NATIVE) before[i] -= msg.value;
        }

        if (p.currencyIn == NATIVE || p.currencyIn == address(WINJ)) {
            // INJ is ONE currency here, whichever form the caller holds it in: any part of
            // `amountIn` may arrive as `msg.value` and the rest is pulled as wINJ. So a wallet holding
            // both spends both in one transaction, and the calldata does not depend on the mix -
            // the caller chooses `msg.value` from its own balances. The input is then converted to
            // the form `currencyIn` names, which is the form the route's first steps expect.
            if (msg.value > p.amountIn) revert ValueMismatch(msg.value, p.amountIn);
            uint256 wrapped = p.amountIn - msg.value;
            if (wrapped != 0) PERMIT2.transferFrom(msg.sender, address(this), wrapped.toUint160(), address(WINJ));
            if (p.currencyIn == NATIVE) {
                if (wrapped != 0) WINJ.withdraw(wrapped);
            } else if (msg.value != 0) {
                WINJ.deposit{value: msg.value}();
            }
        } else {
            if (msg.value != 0) revert ValueMismatch(msg.value, 0);
            PERMIT2.transferFrom(msg.sender, address(this), p.amountIn.toUint160(), p.currencyIn);
        }

        for (uint256 i; i < p.steps.length; ++i) {
            _runStep(p.steps[i], i, touched, before, p.deadline);
        }

        amountOut = _payOut(p, touched, before);
        emit Routed(msg.sender, p.recipient, p.currencyOut, p.currencyIn, p.amountIn, amountOut);
    }

    /// Output to `recipient`, the fee to `feeRecipient`, and every other currency's remainder back
    /// to the caller. A function of its own only to keep `_execute`'s frame inside the stack.
    function _payOut(RouteParams calldata p, address[] memory touched, uint256[] memory before)
        private
        returns (uint256 amountOut)
    {
        // Rounded down, so the user is never charged a wei more than the rate.
        uint256 realised = _held(p.currencyOut, touched, before);
        uint256 fee = (realised * p.feeBps) / BPS;
        amountOut = realised - fee;
        if (amountOut < p.minimumReceive) revert InsufficientOutput(amountOut, p.minimumReceive);

        // Every other currency's remainder - unspent input, a Helix leg's tick-floored change, a
        // split's rounding - goes back to the caller. Measured before anything is sent, so the
        // output transfer cannot be mistaken for dust and vice versa.
        uint256[] memory dust = new uint256[](touched.length);
        for (uint256 i; i < touched.length; ++i) {
            if (touched[i] != p.currencyOut) dust[i] = _held(touched[i], touched, before);
        }

        _send(p.currencyOut, p.recipient, amountOut);
        if (fee != 0) {
            _send(p.currencyOut, p.feeRecipient, fee);
            emit FeePaid(p.feeRecipient, p.currencyOut, fee);
        }
        for (uint256 i; i < touched.length; ++i) {
            if (dust[i] != 0) _send(touched[i], msg.sender, dust[i]);
        }
    }

    /// @inheritdoc ILockCallback
    /// @dev The same three gates as `ChoiceRouter.lockAcquired`: WHO (the vault whose lock is in
    /// progress), WHAT (exactly the bytes `_runInfinity` handed to `lock`), HOW OFTEN (once - the
    /// hash is cleared before the stage runs).
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != _activeVault()) revert NotVault();
        if (keccak256(data) != _stagePayloadHash()) revert StagePayloadMismatch();
        _setStagePayloadHash(bytes32(0));

        (InfinityStage memory stage, uint256 entry, uint256 stepIndex) =
            abi.decode(data, (InfinityStage, uint256, uint256));

        _swapHops(stage, entry, stepIndex);
        _settleStage(stage);
        return "";
    }

    // ── steps ─────────────────────────────────────────────────────────────

    function _runStep(Step calldata s, uint256 i, address[] memory touched, uint256[] memory before, uint256 deadline)
        private
    {
        if (s.shareBps == 0 || s.shareBps > BPS) revert BadShare(i);
        if (s.tokenIn == s.tokenOut) revert BadStep(i);

        uint256 amount = (_held(s.tokenIn, touched, before) * s.shareBps) / BPS;
        if (amount == 0) revert StepInputEmpty(i);

        uint256 outBefore = _balance(s.tokenOut);

        if (s.kind == Kind.Wrap) {
            if (s.tokenIn != NATIVE || s.tokenOut != address(WINJ)) revert BadStep(i);
            WINJ.deposit{value: amount}();
        } else if (s.kind == Kind.Unwrap) {
            if (s.tokenIn != address(WINJ) || s.tokenOut != NATIVE) revert BadStep(i);
            WINJ.withdraw(amount);
        } else if (s.kind == Kind.Infinity) {
            _runInfinity(s, i, amount);
        } else if (s.kind == Kind.Solidly) {
            _runSolidly(s, i, amount);
        } else if (s.kind == Kind.Helix) {
            _runHelix(s, i, amount, deadline);
        } else {
            _runAdapter(s, i, amount);
        }

        if (_balance(s.tokenOut) <= outBefore) revert StepPaidNothing(i);
    }

    /// One lock on an allowlisted vault. The stage is checked BEFORE the lock, against the step it
    /// belongs to: every hop that takes a share of the entry must spend the step's own `tokenIn`,
    /// and the shares may not add up to more than the entry. Without that, a stage could settle a
    /// debt out of money the route had set aside for a later step.
    function _runInfinity(Step calldata s, uint256 i, uint256 entry) private {
        InfinityStage memory stage = abi.decode(s.data, (InfinityStage));
        address vault = address(stage.vault);
        if (!allowedVault[vault]) revert VaultNotAllowed(vault);
        if (stage.hops.length == 0) revert EmptyStage(i);
        if (stage.hops[0].entryBps == 0) revert NothingToChain(i, 0);

        uint256 allocated;
        for (uint256 j; j < stage.hops.length; ++j) {
            Hop memory hop = stage.hops[j];
            if (hop.entryBps == 0) continue;
            if (_hopIn(hop) != s.tokenIn) revert HopInputMismatch(i, j);
            allocated += hop.entryBps;
        }
        if (allocated > BPS) revert StageOverAllocated(i);

        // Encoded once and hashed, rather than encoded inline: the hash is what makes the bytes
        // that come back through `lockAcquired` provably the bytes that went out.
        bytes memory payload = abi.encode(stage, entry, i);

        _setActiveVault(vault);
        _setStagePayloadHash(keccak256(payload));
        stage.vault.lock(payload);
        _setActiveVault(address(0));
        _setStagePayloadHash(bytes32(0));
    }

    /// 🔑 A Solidly pair takes the OUTPUT amount as an argument and checks its own invariant
    /// afterwards, so the output is asked of the pair first. That is not an oracle read: it is the
    /// same state, in the same transaction, that `swap` is about to enforce - which is why both the
    /// volatile and the stable curve work here without this contract knowing which one it is.
    function _runSolidly(Step calldata s, uint256 i, uint256 amount) private {
        if (s.tokenIn == NATIVE || s.tokenOut == NATIVE) revert BadStep(i);
        (address pair, bool zeroForOne) = abi.decode(s.data, (address, bool));

        uint256 out = ISolidlyPair(pair).getAmountOut(amount, s.tokenIn);
        if (out == 0) revert StepPaidNothing(i);

        IERC20(s.tokenIn).safeTransfer(pair, amount);
        ISolidlyPair(pair).swap(zeroForOne ? 0 : out, zeroForOne ? out : 0, address(this), "");
    }

    /// The precompile names INJ `address(0)` and refuses wINJ, so a step naming wINJ on either side
    /// is malformed rather than something to translate silently - a route that needs native INJ
    /// for a Helix leg says so with an `Unwrap` step.
    function _runHelix(Step calldata s, uint256 i, uint256 amount, uint256 deadline) private {
        if (s.tokenIn == address(WINJ) || s.tokenOut == address(WINJ)) revert BadStep(i);
        string memory marketId = abi.decode(s.data, (string));
        HELIX.swapExactInputV1(s.tokenIn, marketId, amount, 0, address(this), deadline);
    }

    /// Paid first, then asked - the Solidly shape, generalised: the adapter is sent exactly this
    /// step's input and told to deliver here. What it sends back of `tokenIn` (a capped or partial
    /// fill) is route money again, spent by a later step or refunded as dust; what it delivers of
    /// `tokenOut` is measured by `_runStep`, never taken from its return value (which is decoded,
    /// so an adapter must return one). Anything it sends of a third token is outside `_touched`
    /// and stays here for good. Native INJ is refused on both sides: `receive()` takes it only
    /// from senders this contract trusts, and an adapter is not one.
    function _runAdapter(Step calldata s, uint256 i, uint256 amount) private {
        if (s.tokenIn == NATIVE || s.tokenOut == NATIVE) revert BadStep(i);
        (address adapter, bytes memory adapterData) = abi.decode(s.data, (address, bytes));
        if (adapter.code.length == 0) revert BadStep(i);

        IERC20(s.tokenIn).safeTransfer(adapter, amount);
        IChoiceAdapter(adapter).swap(s.tokenIn, s.tokenOut, amount, address(this), adapterData);
    }

    // ── Infinity internals ────────────────────────────────────────────────

    function _swapHops(InfinityStage memory stage, uint256 entry, uint256 stepIndex) private {
        for (uint256 j; j < stage.hops.length; ++j) {
            Hop memory hop = stage.hops[j];
            Currency inCurrency = hop.zeroForOne ? hop.key.currency0 : hop.key.currency1;

            uint256 amountIn;
            if (hop.entryBps == 0) {
                int256 delta = stage.vault.currencyDelta(address(this), inCurrency);
                if (delta <= 0) revert NothingToChain(stepIndex, j);
                // forge-lint: disable-next-line(unsafe-typecast) - guarded positive above.
                amountIn = uint256(delta);
            } else {
                amountIn = (entry * hop.entryBps) / BPS;
            }

            // Every swap runs to the extreme price bound; `minimumReceive` is the only guard.
            if (hop.bin) {
                IBinPoolManager(address(hop.key.poolManager))
                    .swap(hop.key, hop.zeroForOne, -amountIn.toInt256().toInt128(), hop.hookData);
            } else {
                ICLPoolManager(address(hop.key.poolManager))
                    .swap(
                        hop.key,
                        ICLPoolManager.SwapParams({
                            zeroForOne: hop.zeroForOne,
                            amountSpecified: -amountIn.toInt256(),
                            sqrtPriceLimitX96: hop.zeroForOne
                                ? TickMath.MIN_SQRT_RATIO + 1
                                : TickMath.MAX_SQRT_RATIO - 1
                        }),
                        hop.hookData
                    );
            }
        }
    }

    /// Debts first, then credits: the vault pays a credit out of real reserves, so taking before
    /// settling can fail on a vault that is exactly funded. Amounts are read from the vault's
    /// ledger, never from a swap's return value - which is what neutralises hooks that return
    /// deltas, and a forged pool manager that credits nothing.
    function _settleStage(InfinityStage memory stage) private {
        Currency[] memory currencies = _stageCurrencies(stage);

        for (uint256 i; i < currencies.length; ++i) {
            int256 delta = stage.vault.currencyDelta(address(this), currencies[i]);
            if (delta >= 0) continue;
            // forge-lint: disable-next-line(unsafe-typecast) - magnitude of a known negative.
            uint256 owed = uint256(-delta);
            stage.vault.sync(currencies[i]);
            if (currencies[i].isNative()) {
                stage.vault.settle{value: owed}();
            } else {
                IERC20(Currency.unwrap(currencies[i])).safeTransfer(address(stage.vault), owed);
                stage.vault.settle();
            }
        }
        for (uint256 i; i < currencies.length; ++i) {
            int256 delta = stage.vault.currencyDelta(address(this), currencies[i]);
            if (delta <= 0) continue;
            // forge-lint: disable-next-line(unsafe-typecast) - guarded positive above.
            stage.vault.take(currencies[i], address(this), uint256(delta));
        }
    }

    function _hopIn(Hop memory hop) private pure returns (address) {
        return Currency.unwrap(hop.zeroForOne ? hop.key.currency0 : hop.key.currency1);
    }

    function _stageCurrencies(InfinityStage memory stage) private pure returns (Currency[] memory out) {
        out = new Currency[](stage.hops.length * 2);
        uint256 n;
        for (uint256 i; i < stage.hops.length; ++i) {
            n = _pushCurrency(out, n, stage.hops[i].key.currency0);
            n = _pushCurrency(out, n, stage.hops[i].key.currency1);
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _pushCurrency(Currency[] memory list, uint256 n, Currency c) private pure returns (uint256) {
        for (uint256 i; i < n; ++i) {
            if (list[i] == c) return n;
        }
        list[n] = c;
        return n + 1;
    }

    // ── accounting ────────────────────────────────────────────────────────

    /// @dev Every currency the route can move, deduplicated: the endpoints, every step's two
    /// sides, and both sides of every Infinity pool - a stage can materialise an intermediate that
    /// is neither its step's input nor its output, and that must come back as dust, not strand.
    function _touched(RouteParams calldata p) private pure returns (address[] memory out) {
        uint256 bound = 2 + p.steps.length * 2;
        InfinityStage[] memory stages = new InfinityStage[](p.steps.length);
        for (uint256 i; i < p.steps.length; ++i) {
            if (p.steps[i].kind != Kind.Infinity) continue;
            stages[i] = abi.decode(p.steps[i].data, (InfinityStage));
            bound += stages[i].hops.length * 2;
        }

        out = new address[](bound);
        uint256 n;
        n = _push(out, n, p.currencyIn);
        n = _push(out, n, p.currencyOut);
        for (uint256 i; i < p.steps.length; ++i) {
            n = _push(out, n, p.steps[i].tokenIn);
            n = _push(out, n, p.steps[i].tokenOut);
            Hop[] memory hops = stages[i].hops;
            for (uint256 j; j < hops.length; ++j) {
                n = _push(out, n, Currency.unwrap(hops[j].key.currency0));
                n = _push(out, n, Currency.unwrap(hops[j].key.currency1));
            }
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _push(address[] memory list, uint256 n, address c) private pure returns (uint256) {
        for (uint256 i; i < n; ++i) {
            if (list[i] == c) return n;
        }
        list[n] = c;
        return n + 1;
    }

    /// What the ROUTE holds of `c`: the balance above its pre-route snapshot.
    function _held(address c, address[] memory touched, uint256[] memory before) private view returns (uint256) {
        uint256 bal = _balance(c);
        for (uint256 i; i < touched.length; ++i) {
            if (touched[i] != c) continue;
            if (bal < before[i]) revert RouteOverspent(c);
            return bal - before[i];
        }
        // Unreachable for a well-formed route: every step token is in `touched`.
        revert RouteOverspent(c);
    }

    function _balance(address c) private view returns (uint256) {
        return c == NATIVE ? address(this).balance : IERC20(c).balanceOf(address(this));
    }

    function _send(address c, address to, uint256 amount) private {
        if (c == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed(to);
        } else {
            IERC20(c).safeTransfer(to, amount);
        }
    }

    // ── transient gates ───────────────────────────────────────────────────

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

    function _setStagePayloadHash(bytes32 payloadHash) private {
        assembly ("memory-safe") {
            tstore(STAGE_PAYLOAD_SLOT, payloadHash)
        }
    }

    function _stagePayloadHash() private view returns (bytes32 payloadHash) {
        assembly ("memory-safe") {
            payloadHash := tload(STAGE_PAYLOAD_SLOT)
        }
    }
}
