// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {ProtocolFeeController} from "infinity-core/src/ProtocolFeeController.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {ProtocolFeeLibrary} from "infinity-core/src/libraries/ProtocolFeeLibrary.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ChoiceFeeController} from "../src/fees/ChoiceFeeController.sol";
import {IBurnSink} from "../src/interfaces/IBurnSink.sol";
import {LaunchPoolGuardHook} from "../src/launchpad/LaunchPoolGuardHook.sol";

/// @dev Stands in for whichever real sink wins D8; records what it was handed.
contract RecordingBurnSink is IBurnSink {
    uint256 public received;
    Currency public lastCurrency;

    function burn(Currency currency, uint256 amount) external {
        lastCurrency = currency;
        received += amount;
    }

    receive() external payable {}
}

contract RevertingBurnSink is IBurnSink {
    function burn(Currency, uint256) external pure {
        revert("sink down");
    }
}

contract ChoiceFeeControllerTest is Test {
    using stdStorage for StdStorage;
    using CLPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;

    Vault internal vault;
    CLPoolManager internal poolManager;
    ChoiceFeeController internal controller;
    RecordingBurnSink internal sink;
    MockERC20 internal token;
    LaunchPoolGuardHook internal guardHook;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    /// @dev The whole 1.00% tier on the LP leg, which is what a graduate carries (D31).
    uint24 internal constant LAUNCH_LP_FEE = 10_000;
    int24 internal constant LAUNCH_TICK_SPACING = 200;

    address internal constant TREASURY = address(0x7EA);
    address internal constant TIMELOCK = address(0x71E);
    address internal constant RANDOM = address(0xBEEF);

    function setUp() public {
        vault = new Vault();
        poolManager = new CLPoolManager(vault);
        vault.registerApp(address(poolManager));

        sink = new RecordingBurnSink();
        controller = new ChoiceFeeController(address(poolManager), TREASURY, sink);
        // collectProtocolFees reverts with InvalidCaller for anyone but the registered
        // controller, so this wiring is part of what the tests exercise.
        poolManager.setProtocolFeeController(controller);
        controller.transferOwnership(TIMELOCK);
        vm.prank(TIMELOCK);
        controller.acceptOwnership();

        token = new MockERC20("Token", "TKN", 18);

        // A0/D30: the launch-pool gate. This test contract stands in for the settler, so it
        // can create pools keyed to the hook the way `InfinitySettler` does on chain.
        guardHook = new LaunchPoolGuardHook(TIMELOCK, address(this));
        vm.prank(TIMELOCK);
        controller.setLaunchPoolGuardHook(guardHook);

        (tokenA, tokenB) = _orderedPair();
    }

    /// @dev Put `amount` of protocol fee on the books the way a swap would, then let the
    /// controller collect it. Three things have to line up or `collectProtocolFees` reverts:
    /// the manager's accrued balance, the vault's per-app reserve it is paid out of, and the
    /// vault actually holding the tokens. Written through `stdstore` rather than hand-computed
    /// slots so an upstream storage-layout change surfaces as a clear failure here.
    function _accrueProtocolFee(uint256 amount) internal returns (Currency currency) {
        currency = Currency.wrap(address(token));
        token.mint(address(vault), amount);
        stdstore.target(address(poolManager)).sig("protocolFeesAccrued(address)").with_key(address(token))
            .checked_write(amount);
        stdstore.target(address(vault)).sig("reservesOfApp(address,address)").with_key(address(poolManager))
            .with_key(address(token)).checked_write(amount);
    }

    // ---------------------------------------------------------------- fee policy

    function test_inheritsUpstreamSplitRatio() public view {
        assertEq(controller.protocolFeeSplitRatio(), 33 * 1e4, "plan D10: 33% of the total fee");
    }

    /// @dev The §4 tier table is a claim about what LPs, the treasury and the auction each
    /// get. This checks the claim against the controller's own arithmetic rather than
    /// against the table being retyped correctly.
    function test_tierTableMatchesTheController() public view {
        uint24[4] memory totalTiers = [uint24(100), 500, 3000, 10_000];
        uint24[4] memory expectedLpFee = [uint24(67), 335, 2011, 6722]; // plan §4, column 2

        for (uint256 i = 0; i < totalTiers.length; i++) {
            uint24 lpFee = controller.getLPFeeFromTotalFee(totalTiers[i]);
            assertEq(lpFee, expectedLpFee[i], "plan tier table drifted from the controller");

            uint24 oneWay = uint24(uint256(totalTiers[i]) * 33 / 100);
            assertLe(oneWay, ProtocolFeeLibrary.MAX_PROTOCOL_FEE, "over the 0.4% cap");
        }
    }

    // ---------------------------------------------------------------- harvest

    function test_harvestSplitsFiftyFiftyAndIsPermissionless() public {
        vm.prank(TIMELOCK);
        controller.setTreasuryBps(5_000); // unpark: plan D10's 50/50
        Currency currency = _accrueProtocolFee(1_000_000);

        // Called by an arbitrary address: revenue must not depend on a privileged keeper.
        vm.prank(RANDOM);
        (uint256 toTreasury, uint256 toBurn) = controller.harvest(currency);

        assertEq(toTreasury, 500_000);
        assertEq(toBurn, 500_000);
        assertEq(token.balanceOf(TREASURY), 500_000, "treasury leg");
        assertEq(sink.received(), 500_000, "burn leg notified");
        assertEq(token.balanceOf(address(sink)), 500_000, "burn leg funded before notify");
        assertEq(token.balanceOf(address(controller)), 0, "nothing stranded in the controller");
    }

    /// @dev An odd amount is where a second multiplication would strand a wei on every
    /// harvest; the remainder must go to the burn leg instead.
    function test_harvestLeavesNoDustBehind() public {
        vm.prank(TIMELOCK);
        controller.setTreasuryBps(5_000);
        Currency currency = _accrueProtocolFee(999_999);

        (uint256 toTreasury, uint256 toBurn) = controller.harvest(currency);

        assertEq(toTreasury + toBurn, 999_999, "split must be exhaustive");
        assertEq(token.balanceOf(address(controller)), 0, "dust stranded in the controller");
    }

    function testFuzz_harvestIsAlwaysExhaustive(uint96 amount, uint16 bps) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        bps = uint16(bound(bps, 0, 10_000));
        vm.prank(TIMELOCK);
        controller.setTreasuryBps(bps);

        Currency currency = _accrueProtocolFee(amount);
        (uint256 toTreasury, uint256 toBurn) = controller.harvest(currency);

        assertEq(toTreasury + toBurn, amount, "split must be exhaustive at any ratio");
        assertEq(token.balanceOf(address(controller)), 0, "nothing stranded");
    }

    /// @dev The shipping default. Everything reaches the treasury and no sink is touched, so
    /// the controller is deployable and revenue is collectable before the burn path is settled.
    function test_parkedByDefaultSendsEverythingToTreasuryWithoutASink() public {
        assertEq(controller.treasuryBps(), 10_000, "must ship parked");

        ChoiceFeeController parked = new ChoiceFeeController(address(poolManager), TREASURY, IBurnSink(address(0)));
        poolManager.setProtocolFeeController(parked);

        Currency currency = _accrueProtocolFee(1_000);
        (uint256 toTreasury, uint256 toBurn) = parked.harvest(currency);

        assertEq(toTreasury, 1_000);
        assertEq(toBurn, 0, "nothing is burnt while parked");
        assertEq(token.balanceOf(TREASURY), 1_000);
    }

    /// @dev Unparking without wiring a sink must fail loudly rather than leave the burn share
    /// sitting in the controller looking like revenue nobody is watching.
    function test_unparkingWithoutASinkReverts() public {
        ChoiceFeeController parked = new ChoiceFeeController(address(poolManager), TREASURY, IBurnSink(address(0)));
        poolManager.setProtocolFeeController(parked);
        parked.setTreasuryBps(5_000);

        Currency currency = _accrueProtocolFee(1_000);
        vm.expectRevert(ChoiceFeeController.BurnSinkNotSet.selector);
        parked.harvest(currency);
    }

    function test_harvestRevertsWhenThereIsNothingToCollect() public {
        vm.expectRevert(ChoiceFeeController.NothingToHarvest.selector);
        controller.harvest(Currency.wrap(address(token)));
    }

    /// @dev A broken sink must fail the whole harvest, not quietly leave the burn share in
    /// the controller where it reads as revenue nobody is watching.
    function test_harvestRevertsIfTheBurnSinkReverts() public {
        RevertingBurnSink broken = new RevertingBurnSink();
        vm.startPrank(TIMELOCK);
        controller.setBurnSink(broken);
        controller.setTreasuryBps(5_000);
        vm.stopPrank();

        Currency currency = _accrueProtocolFee(1_000);
        vm.expectRevert();
        controller.harvest(currency);
    }

    function test_pendingProtocolFeeReportsWhatAHarvestWouldMove() public {
        Currency currency = _accrueProtocolFee(4_242);
        assertEq(controller.pendingProtocolFee(currency), 4_242);
    }

    // ---------------------------------------------------------------- access control

    function test_onlyOwnerCanRedirectRevenue() public {
        vm.startPrank(RANDOM);
        vm.expectRevert();
        controller.setTreasury(RANDOM);
        vm.expectRevert();
        controller.setBurnSink(IBurnSink(RANDOM));
        vm.expectRevert();
        controller.setTreasuryBps(10_000);
        vm.stopPrank();
    }

    function test_treasuryBpsCannotExceedOneHundredPercent() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(ChoiceFeeController.InvalidTreasuryBps.selector);
        controller.setTreasuryBps(10_001);
    }

    function test_ownerIsTheTimelock() public view {
        assertEq(controller.owner(), TIMELOCK, "plan D13: the timelock owns the fee policy");
    }

    // ------------------------------------------------- A0 / D30: the launch-pool separation

    /// @dev The whole point: a pool keyed to the launch-pool guard hook stops paying into
    /// `protocolFeesAccrued`, so that global bucket holds only Choice's own revenue.
    function test_zeroingALaunchPoolKeyTakesItsProtocolFeeToZero() public {
        PoolKey memory key = _openPool(guardHook, LAUNCH_LP_FEE);

        (,, uint24 before,) = poolManager.getSlot0(key.toId());
        assertGt(before, 0, "the pool was born at zero - the test proves nothing");

        // Permissionless: an arbitrary address, not the timelock and not a settler.
        vm.prank(RANDOM);
        controller.zeroLaunchPoolProtocolFee(key);

        (,, uint24 protocolFee,) = poolManager.getSlot0(key.toId());
        assertEq(protocolFee, 0, "a launch pool still charges a protocol fee");
    }

    /// @dev The gate, and the reason permissionless is safe. `key.hooks` is part of a pool's
    /// identity and only an allowlisted settler can create a pool carrying the guard hook, so
    /// anything else is somebody else's pool and must be untouchable.
    function test_aKeyThatIsNotALaunchPoolCannotBeZeroed() public {
        PoolKey memory ordinary = _openPool(IHooks(address(0)), 6722);

        vm.prank(RANDOM);
        vm.expectRevert(abi.encodeWithSelector(ChoiceFeeController.NotALaunchPool.selector, IHooks(address(0))));
        controller.zeroLaunchPoolProtocolFee(ordinary);

        (,, uint24 protocolFee,) = poolManager.getSlot0(ordinary.toId());
        assertGt(protocolFee, 0, "an ordinary Choice pool was zeroed");
    }

    /// @dev A DIFFERENT hook is not the gate either. The check is identity, not "has a hook".
    function test_aPoolKeyedToAnotherHookCannotBeZeroed() public {
        LaunchPoolGuardHook otherHook = new LaunchPoolGuardHook(TIMELOCK, address(this));
        PoolKey memory foreign = _openPool(otherHook, LAUNCH_LP_FEE);

        vm.expectRevert(abi.encodeWithSelector(ChoiceFeeController.NotALaunchPool.selector, otherHook));
        controller.zeroLaunchPoolProtocolFee(foreign);
    }

    /// @dev `InfinitySettler.settle` calls this on every graduation and a keeper may call it
    /// again afterwards, so a second call has to be a no-op rather than a revert.
    function test_zeroingIsIdempotent() public {
        PoolKey memory key = _openPool(guardHook, LAUNCH_LP_FEE);

        controller.zeroLaunchPoolProtocolFee(key);
        controller.zeroLaunchPoolProtocolFee(key);
        vm.prank(RANDOM);
        controller.zeroLaunchPoolProtocolFee(key);

        (,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(key.toId());
        assertEq(protocolFee, 0);
        assertEq(lpFee, LAUNCH_LP_FEE, "the LP leg moved - only the protocol fee should have");
    }

    /// @dev Unset is the state a fresh deployment is in: the fee controllers go out in script
    /// 02 and the guard hook does not exist until script 05. It must refuse rather than match
    /// a hookless key against `address(0)` and zero an arbitrary pool.
    function test_refusesToRunWhileTheGateIsUnset() public {
        PoolKey memory hookless = _openPool(IHooks(address(0)), 6722);
        vm.prank(TIMELOCK);
        controller.setLaunchPoolGuardHook(IHooks(address(0)));

        vm.expectRevert(ChoiceFeeController.LaunchPoolGuardHookNotSet.selector);
        controller.zeroLaunchPoolProtocolFee(hookless);
    }

    /// @dev The pool must exist. Zeroing something that was never initialised would otherwise
    /// look like a success and leave the real pool, whenever it is created, paying the fee.
    function test_zeroingAPoolThatWasNeverInitialisedReverts() public {
        PoolKey memory key = _launchKey(guardHook, LAUNCH_LP_FEE);
        vm.expectRevert();
        controller.zeroLaunchPoolProtocolFee(key);
    }

    /// @dev Upstream's own check, kept for the same reason: this controller is the fee
    /// controller of exactly one manager, and a key naming another one is a mistake worth a
    /// legible error rather than that manager's `InvalidCaller`.
    function test_zeroingRejectsAKeyForAnotherPoolManager() public {
        PoolKey memory key = _launchKey(guardHook, LAUNCH_LP_FEE);
        key.poolManager = IPoolManager(address(0xDEAD));

        vm.expectRevert(ProtocolFeeController.InvalidPoolManager.selector);
        controller.zeroLaunchPoolProtocolFee(key);
    }

    function test_onlyOwnerCanMoveTheLaunchPoolGate() public {
        vm.prank(RANDOM);
        vm.expectRevert();
        controller.setLaunchPoolGuardHook(guardHook);
    }

    /// @dev A codeless address could never key a pool the manager accepts, so a gate pointed
    /// at one is a typo. Refuse it where the error says what is wrong.
    function test_theLaunchPoolGateRejectsAnAddressWithNoCode() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(ChoiceFeeController.HookHasNoCode.selector, RANDOM));
        controller.setLaunchPoolGuardHook(IHooks(RANDOM));
    }

    // -------------------------------------------------------------------------- helpers

    function _launchKey(IHooks hooks, uint24 lpFee) internal view returns (PoolKey memory) {
        uint16 bitmap = address(hooks) == address(0) ? 0 : hooks.getHooksRegistrationBitmap();
        return PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            hooks: hooks,
            poolManager: IPoolManager(address(poolManager)),
            fee: lpFee,
            parameters: bytes32(uint256(bitmap)).setTickSpacing(LAUNCH_TICK_SPACING)
        });
    }

    function _openPool(IHooks hooks, uint24 lpFee) internal returns (PoolKey memory key) {
        key = _launchKey(hooks, lpFee);
        poolManager.initialize(key, uint160(FixedPoint96.Q96));
    }

    function _orderedPair() internal returns (MockERC20 first, MockERC20 second) {
        first = new MockERC20("A", "A", 18);
        second = new MockERC20("B", "B", 18);
        if (address(first) > address(second)) (first, second) = (second, first);
    }
}
