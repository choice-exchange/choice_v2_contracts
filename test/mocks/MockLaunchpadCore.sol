// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGraduationSettler} from "../../src/interfaces/IGraduationSettler.sol";
import {ILaunchpadCore} from "../../src/interfaces/ILaunchpadCore.sol";

/// @notice A `LaunchpadCore` stand-in whose STORAGE LAYOUT is the thing under test.
///
/// `InfinitySettler` reads `creator` and `creatorFeeShareBps` out of the real core with
/// `extsload` and fixed word offsets, because the deployed core exposes no getter for either.
/// A mock that stored those two fields in its own convenient layout would test nothing. So
/// `Launch`, `LaunchGate` and `PoolKind` below are copied VERBATIM (field order and types)
/// from `shroom_launchpad/contracts/src/LaunchpadCore.sol`, and twelve words of padding put
/// the mapping at slot 12 exactly as in the real core. The compiler derives the packing, so
/// if the settler's offsets are wrong these tests fail rather than agreeing with themselves.
///
/// 🔴 This pins the layout as read on 2026-09-05 against the core deployed at
/// `0xb03fb1c05f7853601ae05ba7e3700a59dc14a71d` (testnet), cross-checked field by field
/// against `LaunchpadViews` at `0x60e12ebaf2d3f8a6249a934d44f502708dcb156d`. The core is not upgradeable, so
/// the layout is frozen per deployment - but a NEW core deploy must be re-checked against
/// this struct and against `LaunchpadViews.getLaunch`, which decodes the same words.
contract MockLaunchpadCore {
    using SafeERC20 for IERC20;

    struct LaunchGate {
        address gateToken;
        uint256 minBalance;
        uint64 windowEndsAt;
        uint16 discountBps;
    }

    enum PoolKind {
        Xyk,
        Clmm
    }

    struct Launch {
        ILaunchpadCore.LaunchState state;
        address creator;
        address token;
        address sink;
        uint8 quoteAsset;
        LaunchGate gate;
        uint64 tradingOpensAt;
        uint64 guardWindowEndsAt;
        uint16 maxBuyBpsInGuardWindow;
        uint64 bindDeadline;
        address settler;
        IERC20 pairAsset;
        uint256 virtualPair;
        uint256 virtualToken;
        uint256 curveSupply;
        uint256 graduationPairTarget;
        uint256 graduationTokenReserve;
        uint256 realPair;
        uint256 tokensSold;
        uint256 refundPairTotal;
        uint256 refundTokensTotal;
        uint256 refundPairPaid;
        uint256 refundTokensReceived;
        uint256 feeEscrowed;
        uint16 tradeFeeBps;
        uint16 creatorFeeShareBps;
        uint16 curveId;
        string bankDenom;
        bool requiresChoiceFactoryDust;
        string metadataURI;
        PoolKind poolKind;
    }

    /// @dev Slots 0-11 in the real core hold admin, keeper, registries and flags. Only their
    /// COUNT matters here: it is what puts `launches` at slot 12.
    uint256[12] private __slots0to11;

    mapping(uint256 => Launch) internal launches; // slot 12

    /// @notice Set by `onSettled`, so a test can tell an atomic graduation from a silent one.
    mapping(uint256 => bool) public settledCallbackFired;

    error NotSettler(address expected);
    error WrongState();

    event Graduated(uint256 indexed launchId);

    function extsload(bytes32 startSlot, uint256 n) external view returns (bytes32[] memory out) {
        out = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 slot = bytes32(uint256(startSlot) + i);
            bytes32 value;
            assembly ("memory-safe") {
                value := sload(slot)
            }
            out[i] = value;
        }
    }

    function getLaunchState(uint256 launchId) external view returns (ILaunchpadCore.LaunchState) {
        return launches[launchId].state;
    }

    function getLaunchRealPair(uint256 launchId) external view returns (uint256) {
        return launches[launchId].realPair;
    }

    function getLaunchPairAsset(uint256 launchId) external view returns (IERC20) {
        return launches[launchId].pairAsset;
    }

    function getLaunchToken(uint256 launchId) external view returns (address) {
        return launches[launchId].token;
    }

    /// @dev Same access control as the real core: the caller must be the settler snapshotted
    /// on THIS launch, and the launch must be mid-settlement.
    function onSettled(uint256 launchId) external {
        Launch storage l = launches[launchId];
        if (msg.sender != l.settler) revert NotSettler(l.settler);
        if (l.state != ILaunchpadCore.LaunchState.PendingSettlement) revert WrongState();
        l.state = ILaunchpadCore.LaunchState.Graduated;
        settledCallbackFired[launchId] = true;
        emit Graduated(launchId);
    }

    // -------------------------------------------------------------------------------------
    // Test plumbing
    // -------------------------------------------------------------------------------------

    function seedLaunch(
        uint256 launchId,
        address creator,
        address token,
        IERC20 pairAsset,
        address settler,
        uint256 realPair,
        uint16 creatorFeeShareBps
    ) external {
        Launch storage l = launches[launchId];
        l.state = ILaunchpadCore.LaunchState.CurveFilled;
        l.creator = creator;
        l.token = token;
        l.pairAsset = pairAsset;
        l.settler = settler;
        l.realPair = realPair;
        l.creatorFeeShareBps = creatorFeeShareBps;
        // Written so a correct decode cannot be an accident: the settler has to pick
        // `creatorFeeShareBps` out of the middle of a populated slot, not out of zeros.
        l.tradeFeeBps = 100;
        l.curveId = 7;
        l.poolKind = PoolKind.Clmm;
    }

    /// @notice Mirrors the real `triggerGraduation`: flip to `PendingSettlement`, push both
    /// legs to the settler, then dispatch. Any revert inside `settle` unwinds all of it.
    function triggerGraduation(uint256 launchId, uint256 poolTokenAmount) external {
        Launch storage l = launches[launchId];
        if (l.state != ILaunchpadCore.LaunchState.CurveFilled) revert WrongState();
        l.state = ILaunchpadCore.LaunchState.PendingSettlement;

        IERC20(l.pairAsset).safeTransfer(l.settler, l.realPair);
        IERC20(l.token).safeTransfer(l.settler, poolTokenAmount);

        IGraduationSettler(l.settler).settle(launchId, poolTokenAmount);
    }

    /// @dev For the layout-canary tests: put a launch into a state the settler is not
    /// expecting, without going through `triggerGraduation`.
    function forceState(uint256 launchId, ILaunchpadCore.LaunchState state) external {
        launches[launchId].state = state;
    }
}
