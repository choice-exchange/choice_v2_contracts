// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";

import {ChoiceRouter} from "../src/router/ChoiceRouter.sol";

/// A pool manager that swaps NOTHING and touches no ledger, so a stage can run to completion
/// without any vault lock existing. It is what lets `HostileVault` below drive a real callback
/// through to the end and then try a second one - the property under test is what the router
/// does on the SECOND call, and a first call that reverted for unrelated reasons would prove
/// nothing (a caught revert also rolls the transient slot back).
contract SilentPoolManager {
    function swap(PoolKey calldata, ICLPoolManager.SwapParams calldata, bytes calldata)
        external
        pure
        returns (BalanceDelta)
    {
        return BalanceDelta.wrap(0);
    }
}

/// An allowlisted vault that does not behave like `Vault`.
///
/// This is the threat the payload binding exists for, and it cannot be expressed with the real
/// `Vault`: allowlisting is the router's whole trust boundary, and an allowlist entry cannot
/// tell a reference deployment from a proxy or a modified fork. `Vault.lock` echoes `data` back
/// verbatim; nothing forces a foreign vault to.
contract HostileVault {
    enum Mode {
        Tamper,
        Twice
    }

    ChoiceRouter public router;
    Mode public mode;

    function arm(ChoiceRouter router_, Mode mode_) external {
        router = router_;
        mode = mode_;
    }

    /// @dev The router calls this as `IVault.lock`.
    function lock(bytes calldata data) external returns (bytes memory) {
        if (mode == Mode.Tamper) {
            // Hand back a DIFFERENT stage: same shape, twice the entry amount. Everything the
            // router settles - destination, currencies, amounts - is read out of these bytes.
            (ChoiceRouter.Stage memory stage, uint256 entry, uint256 stageIndex) =
                abi.decode(data, (ChoiceRouter.Stage, uint256, uint256));
            router.lockAcquired(abi.encode(stage, entry * 2, stageIndex));
        } else {
            router.lockAcquired(data);
            router.lockAcquired(data);
        }
        return "";
    }

    /// @dev Every delta is zero, so `_settleStage` neither settles nor takes.
    function currencyDelta(address, Currency) external pure returns (int256) {
        return 0;
    }
}

/// Two independent Infinity deployments, standing in for Choice and Pumex. That is the whole
/// point of the contract under test, so neither side is mocked: both are the real `Vault` +
/// `CLPoolManager`, and the only thing the router knows about either is its address.
contract ChoiceRouterTest is Test, DeployPermit2 {
    using CLPoolParametersHelper for bytes32;

    address internal constant TIMELOCK = address(0x71E);
    address internal constant USER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);
    uint24 internal constant FEE = 3000;
    int24 internal constant SPACING = 60;
    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;

    // "Choice"
    Vault internal vaultA;
    CLPoolManager internal managerA;
    CLPoolManagerRouter internal seedA;
    // "Pumex"
    Vault internal vaultB;
    CLPoolManager internal managerB;
    CLPoolManagerRouter internal seedB;

    IAllowanceTransfer internal permit2;
    ChoiceRouter internal router;

    MockERC20 internal tokenIn;
    MockERC20 internal mid;
    MockERC20 internal tokenOut;
    MockERC20 internal far;

    PoolKey internal poolA; // tokenIn / mid, on Choice
    PoolKey internal poolA2; // tokenIn / mid, second tier on Choice - for splits
    PoolKey internal poolA3; // mid / far, on Choice - the second leg of a chained stage
    PoolKey internal poolB; // mid / tokenOut, on Pumex
    PoolKey internal poolB2; // far / tokenOut, on Pumex

    function setUp() public {
        vaultA = new Vault();
        managerA = new CLPoolManager(vaultA);
        vaultA.registerApp(address(managerA));
        seedA = new CLPoolManagerRouter(vaultA, managerA);

        vaultB = new Vault();
        managerB = new CLPoolManager(vaultB);
        vaultB.registerApp(address(managerB));
        seedB = new CLPoolManagerRouter(vaultB, managerB);

        permit2 = IAllowanceTransfer(deployPermit2());

        IVault[] memory vaults = new IVault[](2);
        vaults[0] = vaultA;
        vaults[1] = vaultB;
        router = new ChoiceRouter(TIMELOCK, permit2, vaults);

        tokenIn = new MockERC20("IN", "IN", 18);
        mid = new MockERC20("MID", "MID", 18);
        tokenOut = new MockERC20("OUT", "OUT", 18);
        far = new MockERC20("FAR", "FAR", 18);

        poolA = _key(managerA, tokenIn, mid, FEE);
        poolA2 = _key(managerA, tokenIn, mid, 500);
        poolA3 = _key(managerA, mid, far, FEE);
        poolB = _key(managerB, mid, tokenOut, FEE);
        poolB2 = _key(managerB, far, tokenOut, FEE);

        _seed(seedA, managerA, poolA, 1_000_000 ether);
        _seed(seedA, managerA, poolA2, 1_000_000 ether);
        _seed(seedA, managerA, poolA3, 1_000_000 ether);
        _seed(seedB, managerB, poolB, 1_000_000 ether);
        _seed(seedB, managerB, poolB2, 1_000_000 ether);

        tokenIn.mint(USER, 1_000_000 ether);
        vm.startPrank(USER);
        tokenIn.approve(address(permit2), type(uint256).max);
        permit2.approve(address(tokenIn), address(router), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    // ── the reason this contract exists ───────────────────────────────────

    function test_crossVaultRouteHonoursOneEndToEndMinimum() public {
        uint256 amountIn = 1000 ether;
        uint256 quoted = _probeOutput(amountIn);

        ChoiceRouter.RouteParams memory p = _route(amountIn, quoted);
        vm.prank(USER);
        uint256 got = router.execute(p);

        assertEq(got, quoted, "realised output moved between the probe and the run");
        assertEq(tokenOut.balanceOf(RECIPIENT), quoted, "recipient was not paid the output");
        assertEq(tokenIn.balanceOf(USER), 1_000_000 ether - amountIn, "wrong amount was pulled");
        assertEq(mid.balanceOf(address(router)), 0, "intermediate was left in the router");
        assertEq(tokenOut.balanceOf(address(router)), 0, "output was left in the router");
    }

    /// The guard is on what the user RECEIVES, not on each leg. Here leg 1 is untouched and
    /// would pass any per-leg minimum quoted for it, while the far side of the route has moved
    /// - which is exactly the shape a per-leg check cannot see.
    function test_aMovedFarLegIsCaughtEvenThoughTheNearLegIsFine() public {
        uint256 amountIn = 1000 ether;
        uint256 quoted = _probeOutput(amountIn);

        // Someone trades the Pumex pool between the quote and the fill.
        mid.mint(address(this), 200_000 ether);
        mid.approve(address(seedB), type(uint256).max);
        seedB.swap(
            poolB,
            ICLPoolManager.SwapParams({
                zeroForOne: Currency.unwrap(poolB.currency0) == address(mid),
                amountSpecified: -int256(200_000 ether),
                sqrtPriceLimitX96: Currency.unwrap(poolB.currency0) == address(mid)
                    ? TickMath.MIN_SQRT_RATIO + 1
                    : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );

        ChoiceRouter.RouteParams memory p = _route(amountIn, quoted);
        vm.prank(USER);
        vm.expectPartialRevert(ChoiceRouter.InsufficientOutput.selector);
        router.execute(p);
    }

    function test_revertsOneWeiUnderTheRealisedOutput() public {
        uint256 amountIn = 1000 ether;
        uint256 quoted = _probeOutput(amountIn);

        ChoiceRouter.RouteParams memory p = _route(amountIn, quoted + 1);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(ChoiceRouter.InsufficientOutput.selector, quoted, quoted + 1));
        router.execute(p);
    }

    // ── single-deployment routes must not come here ───────────────────────

    function test_aSingleVaultRouteIsRefused() public {
        ChoiceRouter.RouteParams memory p = _route(1000 ether, 0);
        // Both stages on Choice: exactly what `INFI_SWAP` does better in one lock.
        p.stages[1].vault = vaultA;
        p.stages[1].hops[0].key = poolA2;
        p.currencyOut = Currency.wrap(address(mid));

        vm.prank(USER);
        vm.expectRevert(ChoiceRouter.NotCrossVault.selector);
        router.execute(p);
    }

    function test_aSingleStageRouteIsRefused() public {
        ChoiceRouter.RouteParams memory p = _route(1000 ether, 0);
        ChoiceRouter.Stage[] memory one = new ChoiceRouter.Stage[](1);
        one[0] = p.stages[0];
        p.stages = one;

        vm.prank(USER);
        vm.expectRevert(ChoiceRouter.NotCrossVault.selector);
        router.execute(p);
    }

    // ── the trust boundary ────────────────────────────────────────────────

    function test_aVaultOutsideTheAllowlistIsRefused() public {
        Vault rogue = new Vault();
        CLPoolManager rogueManager = new CLPoolManager(rogue);
        rogue.registerApp(address(rogueManager));

        ChoiceRouter.RouteParams memory p = _route(1000 ether, 0);
        p.stages[1].vault = rogue;

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(ChoiceRouter.VaultNotAllowed.selector, address(rogue)));
        router.execute(p);
    }

    /// An allowlisted vault is still not allowed to drive the callback whenever it likes: the
    /// gate is the lock IN PROGRESS, so outside a route the decoded stage would be its choice.
    function test_lockAcquiredIsRefusedOutsideARoute() public {
        vm.prank(address(vaultA));
        vm.expectRevert(ChoiceRouter.NotVault.selector);
        router.lockAcquired("");

        vm.prank(USER);
        vm.expectRevert(ChoiceRouter.NotVault.selector);
        router.lockAcquired("");
    }

    // ── the payload binding ───────────────────────────────────────────────

    /// The finding this closes (2026-09-08 audit, R-1). Authenticating the CALLER left the
    /// PAYLOAD chosen by that caller: `lockAcquired` decoded the stage out of whatever bytes
    /// came back, and settlement pays out to `stage.vault`, in the currencies of `stage`'s hop
    /// keys, for amounts read from `stage.vault`. The reference `Vault` echoes `data` verbatim,
    /// so a correct vault cannot forge one - but allowlisting is the whole trust boundary and
    /// it cannot rule out a proxy or a modified fork.
    function test_aVaultThatEchoesADifferentStageIsRefused() public {
        ChoiceRouter.RouteParams memory p = _hostileRoute(HostileVault.Mode.Tamper);

        vm.prank(USER);
        vm.expectRevert(ChoiceRouter.StagePayloadMismatch.selector);
        router.execute(p);
    }

    /// The payload is single-use per lock. Without clearing the slot, a vault could run the
    /// whole stage twice inside one lock - passing the hash check both times - and spend the
    /// route's own funds against a ledger the second pass reads differently.
    ///
    /// 🔑 The first callback must SUCCEED for this to test anything, which is why the stage
    /// runs against `SilentPoolManager`: a first call that reverted would roll the transient
    /// slot back with it and the second would then be indistinguishable from a first.
    function test_theSamePayloadCannotDriveTwoCallbacksInOneLock() public {
        ChoiceRouter.RouteParams memory p = _hostileRoute(HostileVault.Mode.Twice);

        vm.prank(USER);
        vm.expectRevert(ChoiceRouter.StagePayloadMismatch.selector);
        router.execute(p);
    }

    /// An honest route still settles, so the binding costs the normal path nothing. This is the
    /// same two-vault round trip as the first test in this file, asserted here as the control
    /// the two negatives are read against.
    function test_theBindingDoesNotDisturbAnHonestRoute() public {
        ChoiceRouter.RouteParams memory p = _route(1000 ether, 0);

        vm.prank(USER);
        uint256 amountOut = router.execute(p);

        assertGt(amountOut, 0, "the honest route produced nothing");
        assertEq(tokenOut.balanceOf(RECIPIENT), amountOut, "the recipient did not receive the output");
    }

    /// @dev Stage 0 is the real Choice leg, so the router genuinely holds `mid` when the
    /// hostile stage opens; stage 1 is the hostile vault, whose hop names a pool manager that
    /// moves nothing.
    function _hostileRoute(HostileVault.Mode mode) internal returns (ChoiceRouter.RouteParams memory p) {
        HostileVault hostile = new HostileVault();
        hostile.arm(router, mode);
        SilentPoolManager silent = new SilentPoolManager();

        vm.prank(TIMELOCK);
        router.setVault(IVault(address(hostile)), true);

        p = _route(1000 ether, 0);

        PoolKey memory silentKey = _key(CLPoolManager(address(silent)), mid, tokenOut, FEE);
        ChoiceRouter.Hop[] memory hops = new ChoiceRouter.Hop[](1);
        hops[0] = _hop(silentKey, address(mid), 10_000);
        p.stages[1] = ChoiceRouter.Stage({vault: IVault(address(hostile)), hops: hops});
    }

    function test_onlyTheOwnerCanChangeTheAllowlist() public {
        Vault other = new Vault();

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER));
        router.setVault(other, true);

        vm.prank(TIMELOCK);
        router.setVault(other, true);
        assertTrue(router.allowedVault(address(other)));

        vm.prank(TIMELOCK);
        router.setVault(vaultB, false);
        assertFalse(router.allowedVault(address(vaultB)));
    }

    function test_ownerIsTheTimelockAndBothVaultsAreBornAllowed() public view {
        assertEq(router.owner(), TIMELOCK);
        assertTrue(router.allowedVault(address(vaultA)));
        assertTrue(router.allowedVault(address(vaultB)));
    }

    // ── accounting ────────────────────────────────────────────────────────

    /// A balance the router already held is invisible to the route: it is neither spendable as
    /// route input nor sweepable as route dust. Everything is measured as a delta against a
    /// snapshot taken before the pull.
    function test_aDonationIsNeitherSpentNorSwept() public {
        mid.mint(address(router), 77 ether);
        tokenOut.mint(address(router), 13 ether);

        uint256 amountIn = 1000 ether;
        uint256 quoted = _probeOutput(amountIn);

        ChoiceRouter.RouteParams memory p = _route(amountIn, quoted);
        vm.prank(USER);
        uint256 got = router.execute(p);

        assertEq(got, quoted, "the donation leaked into the route's output");
        assertEq(tokenOut.balanceOf(RECIPIENT), quoted, "recipient received the donation");
        assertEq(mid.balanceOf(address(router)), 77 ether, "the mid donation was swept");
        assertEq(tokenOut.balanceOf(address(router)), 13 ether, "the out donation was swept");
        assertEq(mid.balanceOf(USER), 0, "caller was handed a donation as dust");
    }

    function test_unspentInputComesBackToTheCaller() public {
        uint256 amountIn = 1000 ether;
        ChoiceRouter.RouteParams memory p = _route(amountIn, 0);
        // Stage 0 spends only 60% of the entry; the rest is dust the caller gets back.
        p.stages[0].hops[0].entryBps = 6000;

        uint256 before = tokenIn.balanceOf(USER);
        vm.prank(USER);
        router.execute(p);

        assertEq(tokenIn.balanceOf(USER), before - (amountIn * 6000) / 10_000, "the 40% left unspent did not come back");
        assertEq(tokenIn.balanceOf(address(router)), 0, "input was stranded in the router");
    }

    // ── route shapes ──────────────────────────────────────────────────────

    /// A split inside one stage, across two tiers of the same pair. Both legs run in ONE lock,
    /// so leg 2 prices against leg 1's state - the netting the plan's finding 1 describes.
    function test_aSplitInsideAStageRunsInOneLock() public {
        uint256 amountIn = 1000 ether;
        ChoiceRouter.RouteParams memory p = _route(amountIn, 0);

        ChoiceRouter.Hop[] memory hops = new ChoiceRouter.Hop[](2);
        hops[0] = _hop(poolA, address(tokenIn), 6000);
        hops[1] = _hop(poolA2, address(tokenIn), 4000);
        p.stages[0].hops = hops;

        vm.prank(USER);
        uint256 got = router.execute(p);

        assertGt(got, 0, "the split produced nothing");
        assertEq(tokenIn.balanceOf(address(router)), 0, "split left input behind");
        assertEq(mid.balanceOf(address(router)), 0, "split left the intermediate behind");
    }

    /// `entryBps == 0` chains: the second hop consumes the whole delta the first produced, so
    /// the intermediate never becomes a balance and never leaves the vault. Only the currency
    /// that crosses to the other deployment is materialised.
    function test_aChainedHopConsumesTheDeltaOfTheHopBeforeIt() public {
        uint256 amountIn = 1000 ether;

        // Choice: IN -> MID -> FAR in one lock. Pumex: FAR -> OUT.
        ChoiceRouter.Hop[] memory hopsA = new ChoiceRouter.Hop[](2);
        hopsA[0] = _hop(poolA, address(tokenIn), 10_000);
        hopsA[1] = _hop(poolA3, address(mid), 0);
        ChoiceRouter.Hop[] memory hopsB = new ChoiceRouter.Hop[](1);
        hopsB[0] = _hop(poolB2, address(far), 10_000);

        ChoiceRouter.Stage[] memory stages = new ChoiceRouter.Stage[](2);
        stages[0] = ChoiceRouter.Stage({vault: vaultA, hops: hopsA});
        stages[1] = ChoiceRouter.Stage({vault: vaultB, hops: hopsB});

        ChoiceRouter.RouteParams memory p = ChoiceRouter.RouteParams({
            currencyIn: Currency.wrap(address(tokenIn)),
            currencyOut: Currency.wrap(address(tokenOut)),
            amountIn: amountIn,
            minimumReceive: 0,
            recipient: RECIPIENT,
            deadline: block.timestamp + 1,
            stages: stages
        });

        vm.prank(USER);
        uint256 got = router.execute(p);

        assertGt(got, 0, "the chained route produced nothing");
        assertEq(tokenOut.balanceOf(RECIPIENT), got, "recipient was not paid");
        // MID was chained inside the lock, so the router never held it and the caller was
        // never handed it as dust. FAR is the one that crossed deployments.
        assertEq(mid.balanceOf(address(router)), 0, "the chained intermediate was materialised");
        assertEq(mid.balanceOf(USER), 0, "the chained intermediate leaked out as dust");
        assertEq(far.balanceOf(address(router)), 0, "the crossing token was stranded");
    }

    /// @dev Both slots are literals in the contract because inline assembly cannot reference a
    /// computed constant, so this is the only thing standing between a mistyped nibble and two
    /// gates that silently read the wrong word.
    function test_transientSlotMatchesItsDerivation() public pure {
        assertEq(
            uint256(keccak256("choice.v2.router.activeVault")) - 1,
            0xf6d74ac3105b1000971a93f4dbcb94238b3965db702346eeed7fa44221e4b5e9
        );
        assertEq(
            uint256(keccak256("choice.v2.router.stagePayload")) - 1,
            0x9bd89f6d9008db88003b7a3b8977f0f681f4ebefb915840e9f4c4627596ea03c
        );
        assertTrue(
            keccak256("choice.v2.router.activeVault") != keccak256("choice.v2.router.stagePayload"),
            "the two gates would share one word"
        );
    }

    function test_anExpiredDeadlineIsRefused() public {
        ChoiceRouter.RouteParams memory p = _route(1000 ether, 0);
        p.deadline = block.timestamp - 1;

        vm.prank(USER);
        vm.expectRevert(ChoiceRouter.DeadlinePassed.selector);
        router.execute(p);
    }

    // ── helpers ───────────────────────────────────────────────────────────

    /// Runs the route with an unreachable minimum and reads the realised output back out of
    /// the revert, so the expectations above are the chain's own numbers rather than a
    /// hand-computed quote. The revert rolls the swaps back, so nothing is consumed.
    function _probeOutput(uint256 amountIn) internal returns (uint256 realised) {
        ChoiceRouter.RouteParams memory p = _route(amountIn, type(uint256).max);
        vm.prank(USER);
        try router.execute(p) returns (uint256) {
            revert("probe should not have succeeded");
        } catch (bytes memory err) {
            bytes4 sel;
            assembly ("memory-safe") {
                sel := mload(add(err, 0x20))
            }
            assertEq(sel, ChoiceRouter.InsufficientOutput.selector, "probe reverted for another reason");
            (realised,) = abi.decode(_body(err), (uint256, uint256));
        }
    }

    function _body(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = err[i + 4];
        }
    }

    function _route(uint256 amountIn, uint256 minimumReceive)
        internal
        view
        returns (ChoiceRouter.RouteParams memory p)
    {
        ChoiceRouter.Stage[] memory stages = new ChoiceRouter.Stage[](2);

        ChoiceRouter.Hop[] memory hopsA = new ChoiceRouter.Hop[](1);
        hopsA[0] = _hop(poolA, address(tokenIn), 10_000);
        stages[0] = ChoiceRouter.Stage({vault: vaultA, hops: hopsA});

        ChoiceRouter.Hop[] memory hopsB = new ChoiceRouter.Hop[](1);
        hopsB[0] = _hop(poolB, address(mid), 10_000);
        stages[1] = ChoiceRouter.Stage({vault: vaultB, hops: hopsB});

        p = ChoiceRouter.RouteParams({
            currencyIn: Currency.wrap(address(tokenIn)),
            currencyOut: Currency.wrap(address(tokenOut)),
            amountIn: amountIn,
            minimumReceive: minimumReceive,
            recipient: RECIPIENT,
            deadline: block.timestamp + 1,
            stages: stages
        });
    }

    function _hop(PoolKey memory key, address inputToken, uint16 entryBps)
        internal
        pure
        returns (ChoiceRouter.Hop memory)
    {
        return ChoiceRouter.Hop({
            key: key, zeroForOne: Currency.unwrap(key.currency0) == inputToken, entryBps: entryBps, hookData: ""
        });
    }

    function _key(CLPoolManager manager, MockERC20 a, MockERC20 b, uint24 fee) internal pure returns (PoolKey memory) {
        (address c0, address c1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(manager)),
            fee: fee,
            parameters: bytes32(0).setTickSpacing(SPACING)
        });
    }

    function _seed(CLPoolManagerRouter seeder, CLPoolManager manager, PoolKey memory key, uint256 amount) internal {
        manager.initialize(key, SQRT_1_1);
        MockERC20(Currency.unwrap(key.currency0)).mint(address(this), amount);
        MockERC20(Currency.unwrap(key.currency1)).mint(address(this), amount);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(seeder), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(seeder), type(uint256).max);
        seeder.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(amount / 2), salt: bytes32(0)
            }),
            ""
        );
    }
}
