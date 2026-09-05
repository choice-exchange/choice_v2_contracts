// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

/// @title PositionLocker
/// @notice Permanent home for the full-range position a launchpad graduation seeds, and the
/// only thing that can move the fees it earns.
///
/// This is v1's `choice_pool_seeder` Locker in Infinity's shape (plan D11). A graduated
/// launch's liquidity is not the creator's to withdraw: `InfinitySettler` mints the seed
/// position straight to this contract and it never leaves. What the position earns is a
/// different matter - `collect` pulls the accrued LP fees and splits them creator /
/// launchpad treasury by the launch's own `creatorFeeShareBps`, the same share the creator
/// earned on the bonding curve.
///
/// **The split is credited, not pushed.** `collect` records what each side is owed and
/// `claim` pays it out, which are two calls where there used to be one. That is not
/// bookkeeping taste: pushing meant four transfers in a single call - creator and treasury,
/// in each of two currencies - and any one of them reverting took the whole `collect` with
/// it, permanently. A quote asset with a transfer blocklist, or a creator contract that
/// reverts on a native leg, would have frozen the LAUNCHPAD's share of that pool as well as
/// the creator's, with no way to separate them: `creator` is snapshotted at graduation and
/// immutable, and nothing here can skip a leg. Crediting makes one blocked recipient their
/// own problem instead of everyone's.
///
/// **What this contract deliberately cannot do.** There is no `transferFrom`, no `approve`,
/// no `setApprovalForAll` and no generic `modifyLiquidities` passthrough. `collect` is the
/// single path into the position manager and it hard-codes a liquidity delta of zero, so no
/// caller - owner included - can withdraw the underlying liquidity, burn the NFT, or attach
/// a subscriber to it. The owner's powers are limited to *where future* fees go
/// (`setLaunchpadTreasury`), who may register *new* positions (`setSettler`), and sweeping
/// tokens that were donated to this contract. A registered position's creator and split are
/// immutable once written.
///
/// 🔴 Because credited fees now sit here between `collect` and `claim`, `sweep` is bounded by
/// `totalOwed` rather than by the fact that nothing was ever at rest. Miss that and the pull
/// trades a liveness bug for a custody one.
///
/// `collect` and `claim` are both permissionless, for the same reason
/// `ChoiceFeeController.harvest` is: the destinations are fixed at registration, so a caller
/// can only choose *when* the creator and the launchpad get paid, and they pay the gas to do
/// it. `claim` always pays the recipient it names, never its caller.
contract PositionLocker is Ownable2Step, ReentrancyGuardTransient, IERC721Receiver {
    using CurrencyLibrary for Currency;
    using Planner for Plan;

    /// @notice Denominator for `creatorBps`.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The CL position manager holding the NFTs this contract owns.
    ICLPositionManager public immutable POSITION_MANAGER;

    /// @notice A graduated launch's locked seed position. Written once by `register` and
    /// never mutated - the split a launch graduates with is the split it keeps.
    struct LockedPosition {
        uint256 tokenId;
        address creator;
        uint16 creatorBps;
    }

    /// @notice The only address allowed to `register`. Owner-settable so a settler can be
    /// replaced (a new fee tier, a fixed bug) without stranding the positions this one
    /// already locked - registrations are per launch and survive the pointer moving. It also
    /// doubles as the recovery lever: the owner can point this at itself to adopt a position
    /// that reached the locker outside the normal graduation path.
    address public settler;

    /// @notice Receives the non-creator share of every collect.
    address public launchpadTreasury;

    mapping(uint256 launchId => LockedPosition) internal _positions;

    /// @notice tokenId => the launch it was registered under, +1 so that zero reads as unset.
    mapping(uint256 tokenId => uint256 launchIdPlusOne) public registeredTokenIds;

    /// @notice Collected fees credited to a recipient and not yet claimed.
    /// @dev Keyed by the recipient address rather than by launch, so a treasury that changes
    /// between a `collect` and a `claim` cannot take a credit that was earned under the old
    /// one, and so a creator with several launches claims a currency once.
    mapping(Currency currency => mapping(address recipient => uint256 amount)) public owed;

    /// @notice Everything credited and unclaimed in a currency. The part of this contract's
    /// balance that is not its own, and that `sweep` therefore cannot reach.
    mapping(Currency currency => uint256 amount) public totalOwed;

    error NotSettler();
    error AlreadyRegistered(uint256 launchId);
    error TokenAlreadyRegistered(uint256 tokenId);
    error NotRegistered(uint256 launchId);
    error PositionNotHeld(uint256 tokenId);
    error InvalidTokenId();
    error InvalidBps(uint16 bps);
    error ZeroAddress();
    error NothingToCollect(uint256 launchId);
    error NothingToClaim(Currency currency, address recipient);
    error PositionPoolMismatch(uint256 tokenId);
    error PositionHasNoLiquidity(uint256 tokenId);
    error UnexpectedNFT(address token);

    event PositionRegistered(
        uint256 indexed launchId, uint256 indexed tokenId, address indexed creator, uint16 creatorBps
    );
    event FeesCollected(
        uint256 indexed launchId,
        uint256 indexed tokenId,
        uint256 amount0,
        uint256 amount1,
        uint256 creatorAmount0,
        uint256 creatorAmount1
    );
    event FeesClaimed(Currency indexed currency, address indexed recipient, uint256 amount);
    event SettlerUpdated(address oldSettler, address newSettler);
    event LaunchpadTreasuryUpdated(address oldTreasury, address newTreasury);
    event TokenSwept(Currency indexed currency, address indexed to, uint256 amount);

    /// @param _settler The settler, whose CREATE3 address is known before it is deployed. Set
    /// here rather than through a post-deploy `setSettler` so this contract can be born owned
    /// by the timelock instead of by a deployer that still has wiring left to do.
    constructor(ICLPositionManager _positionManager, address _launchpadTreasury, address _owner, address _settler)
        Ownable(_owner)
    {
        if (
            address(_positionManager) == address(0) || _launchpadTreasury == address(0) || _owner == address(0)
                || _settler == address(0)
        ) {
            revert ZeroAddress();
        }
        POSITION_MANAGER = _positionManager;
        launchpadTreasury = _launchpadTreasury;
        settler = _settler;
        emit SettlerUpdated(address(0), _settler);
    }

    // -------------------------------------------------------------------------------------
    // Registration
    // -------------------------------------------------------------------------------------

    /// @notice Record the seed position `InfinitySettler` just minted to this contract.
    /// @dev Called inside `LaunchpadCore.triggerGraduation`, so it must not revert on
    /// anything the settler can get right. Everything below is a check on the position
    /// itself rather than trust in the caller, because the binding it writes is permanent:
    /// a launch pointed at the wrong tokenId can never be repointed, and the fees of the
    /// position it should have named become unclaimable by anyone.
    ///
    /// `ownerOf` alone is a presence check, not a binding one. The settler reads
    /// `nextTokenId()` and then calls `_approvePosm`, which touches the pair asset and the
    /// launch token before the mint happens - so code reachable from either that minted a
    /// position to this contract would take that id, and the real seed would land one later,
    /// held here and registered to nothing. Neither token can do that today (the pad's quote
    /// registry is `onlyAdmin` and a launch token is a `MintBurnBankERC20`), which is a fact
    /// about a contract in another repo and not something a permanent binding should rest on.
    /// @param key The pool the settler just seeded. The position must actually be in it.
    function register(uint256 launchId, uint256 tokenId, address creator, uint16 creatorBps, PoolKey calldata key)
        external
    {
        if (msg.sender != settler) revert NotSettler();
        if (tokenId == 0) revert InvalidTokenId();
        if (creator == address(0)) revert ZeroAddress();
        if (creatorBps > BPS_DENOMINATOR) revert InvalidBps(creatorBps);
        if (_positions[launchId].tokenId != 0) revert AlreadyRegistered(launchId);
        if (registeredTokenIds[tokenId] != 0) revert TokenAlreadyRegistered(tokenId);
        if (IERC721(address(POSITION_MANAGER)).ownerOf(tokenId) != address(this)) revert PositionNotHeld(tokenId);

        (PoolKey memory held,) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        if (PoolId.unwrap(held.toId()) != PoolId.unwrap(key.toId())) revert PositionPoolMismatch(tokenId);
        if (POSITION_MANAGER.getPositionLiquidity(tokenId) == 0) revert PositionHasNoLiquidity(tokenId);

        _positions[launchId] = LockedPosition({tokenId: tokenId, creator: creator, creatorBps: creatorBps});
        registeredTokenIds[tokenId] = launchId + 1;

        emit PositionRegistered(launchId, tokenId, creator, creatorBps);
    }

    // -------------------------------------------------------------------------------------
    // Fees
    // -------------------------------------------------------------------------------------

    /// @notice Pull everything the locked position has earned and credit it to the split.
    /// @dev The plan is `CL_DECREASE_LIQUIDITY` with a delta of **zero** - Infinity's own
    /// collect idiom - so the only credit it can produce is fees owed. `TAKE_PAIR` brings
    /// both currencies here, and what each side is owed is written down rather than sent.
    /// `claim` is what sends it.
    ///
    /// Nothing in this function transfers, so it hands control to nobody and the guard is now
    /// only about the `TAKE_PAIR` leg: a currency that calls back on receipt could reenter
    /// here for another launch. The balance-delta accounting survives that on its own - a
    /// reentrant collect measures its own delta and credits its own launch - but the argument
    /// is subtle enough not to want to rest on it. Transient, so it costs no cold SSTORE.
    /// @return amount0 Fees collected in `currency0`.
    /// @return amount1 Fees collected in `currency1`.
    function collect(uint256 launchId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        LockedPosition memory position = _positions[launchId];
        if (position.tokenId == 0) revert NotRegistered(launchId);

        (PoolKey memory key,) = POSITION_MANAGER.getPoolAndPositionInfo(position.tokenId);

        // Measure what actually arrives rather than trusting the position manager's return:
        // a donation already sitting here must not be paid out as if it were fee revenue,
        // and a fee-on-transfer currency delivers less than the delta says it will.
        uint256 before0 = key.currency0.balanceOfSelf();
        uint256 before1 = key.currency1.balanceOfSelf();

        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.CL_DECREASE_LIQUIDITY, abi.encode(position.tokenId, uint256(0), uint128(0), uint128(0), bytes(""))
        );
        POSITION_MANAGER.modifyLiquidities(
            plan.finalizeModifyLiquidityWithTakePair(key, address(this)), block.timestamp
        );

        amount0 = key.currency0.balanceOfSelf() - before0;
        amount1 = key.currency1.balanceOfSelf() - before1;
        if (amount0 == 0 && amount1 == 0) revert NothingToCollect(launchId);

        uint256 creatorAmount0 = _credit(key.currency0, amount0, position.creator, position.creatorBps);
        uint256 creatorAmount1 = _credit(key.currency1, amount1, position.creator, position.creatorBps);

        emit FeesCollected(launchId, position.tokenId, amount0, amount1, creatorAmount0, creatorAmount1);
    }

    /// @dev The treasury gets the remainder rather than a second multiplication, so integer
    /// division cannot strand dust here on every collect.
    function _credit(Currency currency, uint256 amount, address creator, uint16 creatorBps)
        internal
        returns (uint256 toCreator)
    {
        if (amount == 0) return 0;
        toCreator = amount * creatorBps / BPS_DENOMINATOR;
        uint256 toTreasury = amount - toCreator;
        if (toCreator > 0) owed[currency][creator] += toCreator;
        if (toTreasury > 0) owed[currency][launchpadTreasury] += toTreasury;
        totalOwed[currency] += amount;
    }

    /// @notice Send a recipient everything it has been credited in one currency.
    /// @dev Permissionless, and it always pays `recipient` rather than `msg.sender`: a keeper,
    /// the frontend or the other party can settle somebody's balance for them, and nobody can
    /// redirect it. Credits are zeroed before the transfer, so the only thing a recipient that
    /// takes control here can do is be paid once.
    /// @return amount What was sent.
    function claim(Currency currency, address recipient) external nonReentrant returns (uint256 amount) {
        amount = owed[currency][recipient];
        if (amount == 0) revert NothingToClaim(currency, recipient);

        owed[currency][recipient] = 0;
        totalOwed[currency] -= amount;

        currency.transfer(recipient, amount);
        emit FeesClaimed(currency, recipient, amount);
    }

    // -------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------

    function getPosition(uint256 launchId) external view returns (LockedPosition memory) {
        return _positions[launchId];
    }

    /// @notice The live liquidity of a launch's locked position. Constant by construction -
    /// nothing in this contract can change it - so a reading that ever moves is a bug.
    function positionLiquidity(uint256 launchId) external view returns (uint128) {
        LockedPosition memory position = _positions[launchId];
        if (position.tokenId == 0) revert NotRegistered(launchId);
        return POSITION_MANAGER.getPositionLiquidity(position.tokenId);
    }

    // -------------------------------------------------------------------------------------
    // Owner
    // -------------------------------------------------------------------------------------

    function setSettler(address newSettler) external onlyOwner {
        if (newSettler == address(0)) revert ZeroAddress();
        emit SettlerUpdated(settler, newSettler);
        settler = newSettler;
    }

    function setLaunchpadTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit LaunchpadTreasuryUpdated(launchpadTreasury, newTreasury);
        launchpadTreasury = newTreasury;
    }

    /// @notice Recover a currency that was sent to this contract outside `collect`.
    /// @dev Cannot touch a position: an Infinity position is an ERC721 and there is no path
    /// in this contract that transfers one.
    ///
    /// 🔴 Cannot touch credited fees either, and unlike before that now takes a subtraction
    /// rather than following from the shape of `collect`. Fees sit here between a `collect`
    /// and a `claim`, so what is sweepable is the balance MINUS everything owed - which is
    /// what makes the pull payment a fix rather than a swap of one problem for another.
    function sweep(Currency currency, address to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = currency.balanceOfSelf();
        uint256 reserved = totalOwed[currency];
        amount = balance > reserved ? balance - reserved : 0;
        if (amount > 0) currency.transfer(to, amount);
        emit TokenSwept(currency, to, amount);
    }

    // -------------------------------------------------------------------------------------
    // Receiving
    // -------------------------------------------------------------------------------------

    /// @dev The settler's mint uses ERC721 `_mint`, which never calls this. It exists so a
    /// position can also be `safeTransferFrom`'d in - the migration path for a launch that
    /// was seeded before this contract existed. An NFT that arrives without a matching
    /// `register` is simply locked: this contract has no way to send one back out.
    function onERC721Received(address, address, uint256, bytes calldata) external view override returns (bytes4) {
        if (msg.sender != address(POSITION_MANAGER)) revert UnexpectedNFT(msg.sender);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @dev Reached only if a pool ever pairs native INJ; `TAKE_PAIR` would deliver it here.
    receive() external payable {}
}
