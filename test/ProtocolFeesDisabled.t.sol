// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {ProtocolFeeController} from "infinity-core/src/ProtocolFeeController.sol";
import {ProtocolFeeLibrary} from "infinity-core/src/libraries/ProtocolFeeLibrary.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ChoiceFeeController} from "../src/fees/ChoiceFeeController.sol";
import {IBurnSink} from "../src/interfaces/IBurnSink.sol";

/// @title The mainnet launch policy: Choice's protocol fee parked at zero, and reversible
///
/// @notice Mainnet launches so that partners can route volume against their own liquidity for
/// free. A pool's LP fee is a wash for a partner who IS the LP, so the only real cost to remove
/// is Choice's protocol cut - and `injective_mainnet.json` therefore ships
/// `protocolFeeSplitRatio: 0` and `defaultProtocolFeeForDynamicFeePool: 0`, which script 02
/// hands to both `ChoiceFeeController` constructors.
///
/// This file proves three separate things, because the policy is only safe if all three hold:
///
/// 1. That configuration really is free, on every tier AND on the dynamic-fee path - which is a
///    second, independent lever that a reader naturally assumes the first one covers.
/// 2. It is free from BIRTH, with no post-deploy call, which is what makes it safe under a
///    permissionless `initialize` (nobody can open a pool in a window before governance acts).
/// 3. It is reversible without redeploying anything - and reversing it is TWO different
///    operations, because a pool that already exists never re-reads the controller.
contract ProtocolFeesDisabledTest is Test {
    using CLPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;

    Vault internal vault;

    /// @dev Testnet's policy: upstream's 33%, and 300 on the dynamic path.
    CLPoolManager internal chargingManager;
    ChoiceFeeController internal charging;

    /// @dev Mainnet's policy, exactly as `injective_mainnet.json` states it.
    CLPoolManager internal freeManager;
    ChoiceFeeController internal free;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal constant TREASURY = address(0x7EA);
    address internal constant TIMELOCK = address(0x71E);
    address internal constant RANDOM = address(0xBEEF);

    /// @dev Plan §4, column 2: the LP leg of each of the four tiers Choice ships, with the
    /// tick spacing that goes with it.
    uint24[4] internal LP_FEES = [uint24(67), 335, 2011, 6722];
    int24[4] internal TICK_SPACINGS = [int24(1), 10, 60, 200];

    uint256 internal constant CHOICE_SPLIT_RATIO = 33 * 1e4;
    uint24 internal constant UPSTREAM_DYNAMIC_DEFAULT = 300;

    function setUp() public {
        vault = new Vault();

        chargingManager = new CLPoolManager(vault);
        vault.registerApp(address(chargingManager));
        charging = _controller(chargingManager, CHOICE_SPLIT_RATIO, UPSTREAM_DYNAMIC_DEFAULT);

        freeManager = new CLPoolManager(vault);
        vault.registerApp(address(freeManager));
        free = _controller(freeManager, 0, 0);

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
    }

    // --------------------------------------------------------- 1. the launch configuration

    /// @dev The baseline the rest of the file is measured against. Under testnet's policy every
    /// tier is born CHARGING - so if the free-configuration tests below ever pass vacuously,
    /// this one fails first and says so.
    function test_underTheTestnetPolicyEveryTierIsBornCharging() public {
        for (uint256 i = 0; i < LP_FEES.length; i++) {
            PoolKey memory key = _openPool(chargingManager, LP_FEES[i], TICK_SPACINGS[i]);
            (,, uint24 protocolFee,) = chargingManager.getSlot0(key.toId());
            assertGt(protocolFee, 0, "a tier was born free under a 33% policy");
        }
    }

    /// @dev The launch claim itself, and note what is NOT in this test: no `vm.prank`, no
    /// setter, no governance action of any kind. The pools are born free because that is what
    /// the constructor argument in the address book says, which is the property that matters
    /// under a permissionless `initialize`.
    function test_theMainnetConfigurationIsBornFreeOnEveryTier() public {
        for (uint256 i = 0; i < LP_FEES.length; i++) {
            PoolKey memory key = _openPool(freeManager, LP_FEES[i], TICK_SPACINGS[i]);
            (,, uint24 protocolFee, uint24 lpFee) = freeManager.getSlot0(key.toId());
            assertEq(protocolFee, 0, "a tier still charges Choice's protocol fee");
            assertEq(lpFee, LP_FEES[i], "the LP leg moved - the partner's own fee must not change");
        }
    }

    /// @dev 🔴 THE SECOND LEVER, and the reason the address book carries two numbers. A
    /// dynamic-fee pool never consults `protocolFeeSplitRatio`: `protocolFeeForPool` branches
    /// on the dynamic flag FIRST and answers `defaultProtocolFeeForDynamicFeePool`, which
    /// upstream ships at 300 (0.03%). So a deployment that zeroed only the ratio would still
    /// charge every dynamic-fee pool anybody opened, silently and for that pool's whole life.
    function test_zeroingOnlyTheSplitRatioWouldStillChargeDynamicFeePools() public {
        ChoiceFeeController halfDone = _controller(freeManager, 0, UPSTREAM_DYNAMIC_DEFAULT);
        PoolKey memory dynamicKey = _key(freeManager, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);

        assertEq(halfDone.protocolFeeSplitRatio(), 0, "the ratio lever is off");
        assertGt(halfDone.protocolFeeForPool(dynamicKey), 0, "and the pool is still charged anyway");

        // What the mainnet book actually deploys answers zero on the same key.
        assertEq(free.defaultProtocolFeeForDynamicFeePool(), 0, "mainnet must zero the dynamic default too");
        assertEq(free.protocolFeeForPool(dynamicKey), 0, "the dynamic path is still charging");
    }

    /// @dev The constructor enforces the same bounds the inherited setters do, so a book with a
    /// fat-fingered policy fails the deploy rather than deploying a contract that would have
    /// reverted on the equivalent setter call.
    function test_theConstructorRefusesAPolicyTheSettersWouldRefuse() public {
        // Constructed directly rather than through `_controller`, so the CREATE is the only
        // operation `expectRevert` can be looking at.
        vm.expectRevert(ProtocolFeeController.InvalidProtocolFeeSplitRatio.selector);
        new ChoiceFeeController(address(freeManager), TREASURY, IBurnSink(address(0)), 1e6 + 1, 0);

        vm.expectRevert(ProtocolFeeController.InvalidDefaultProtocolFeeForDynamicFeePool.selector);
        new ChoiceFeeController(
            address(freeManager), TREASURY, IBurnSink(address(0)), 0, ProtocolFeeLibrary.MAX_PROTOCOL_FEE + 1
        );
    }

    // ------------------------------------------------------------- 3. turning them back on

    /// @dev Half of "can we enable fees later": for pools opened AFTER the change, one timelock
    /// call restores the plan §4 tier table. Nothing is redeployed and no pool is touched.
    function test_restoringTheSplitRatioMakesNewPoolsChargeTheTierTableAgain() public {
        _openPool(freeManager, LP_FEES[1], TICK_SPACINGS[1]); // born free

        vm.prank(TIMELOCK);
        free.setProtocolFeeSplitRatio(CHOICE_SPLIT_RATIO);

        // A different tier, so this is genuinely a new pool rather than the one above.
        PoolKey memory key = _openPool(freeManager, LP_FEES[2], TICK_SPACINGS[2]);
        (,, uint24 protocolFee,) = freeManager.getSlot0(key.toId());
        assertEq(protocolFee, _bothDirections(989), "plan section 4: the 0.30% tier protocol leg is 989 pips");
    }

    /// @dev 🔴 The other half, and the standing operational cost of launching free. A pool's
    /// protocol fee is read from the controller exactly ONCE, at `initialize`, and then lives
    /// in that pool's slot0. Restoring the split ratio therefore does not reach a pool that
    /// already exists: each one has to be pushed individually through the inherited
    /// `setProtocolFee`. One timelock call per pool - batchable into a single operation, but
    /// neither free nor automatic, and the count grows with every day fees stay off.
    function test_enablingFeesLaterLeavesExistingPoolsAtZeroUntilEachIsPushed() public {
        PoolKey memory key = _openPool(freeManager, LP_FEES[1], TICK_SPACINGS[1]);
        (,, uint24 born,) = freeManager.getSlot0(key.toId());
        assertEq(born, 0, "the pool was not born free - the test proves nothing");

        vm.prank(TIMELOCK);
        free.setProtocolFeeSplitRatio(CHOICE_SPLIT_RATIO);

        (,, uint24 afterRatio,) = freeManager.getSlot0(key.toId());
        assertEq(afterRatio, 0, "an existing pool re-read the controller - upstream's model changed");

        // The per-pool push. 164 pips is the 0.05% tier's protocol leg (plan §4, column 3).
        vm.prank(TIMELOCK);
        free.setProtocolFee(key, _bothDirections(164));

        (,, uint24 pushed, uint24 lpFee) = freeManager.getSlot0(key.toId());
        assertEq(pushed, _bothDirections(164), "the existing pool never started charging");
        assertEq(lpFee, LP_FEES[1], "the LP leg moved - only the protocol fee should have");
    }

    /// @dev Every lever is `onlyOwner`, and the owner is the timelock. Nobody can turn Choice's
    /// fee on - or back off - without a scheduled, delayed, publicly visible operation.
    function test_onlyTheTimelockCanMoveAnyLever() public {
        vm.startPrank(RANDOM);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDOM));
        free.setProtocolFeeSplitRatio(CHOICE_SPLIT_RATIO);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDOM));
        free.setDefaultProtocolFeeForDynamicFeePool(UPSTREAM_DYNAMIC_DEFAULT);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDOM));
        free.setProtocolFee(_key(freeManager, LP_FEES[1], TICK_SPACINGS[1]), _bothDirections(164));
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------- helpers

    /// @dev Built and wired the way script 02 does it: deployed, pointed at by the manager,
    /// then handed to the timelock through `Ownable2Step`.
    function _controller(CLPoolManager manager, uint256 splitRatio, uint24 dynamicDefault)
        internal
        returns (ChoiceFeeController c)
    {
        c = new ChoiceFeeController(address(manager), TREASURY, IBurnSink(address(0)), splitRatio, dynamicDefault);
        manager.setProtocolFeeController(c);
        c.transferOwnership(TIMELOCK);
        vm.prank(TIMELOCK);
        c.acceptOwnership();
    }

    /// @dev The manager stores one 12-bit fee per direction, packed 1->0 above 0->1.
    function _bothDirections(uint24 oneWay) internal pure returns (uint24) {
        return oneWay + (oneWay << 12);
    }

    function _key(CLPoolManager manager, uint24 lpFee, int24 tickSpacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(manager)),
            fee: lpFee,
            parameters: bytes32(uint256(0)).setTickSpacing(tickSpacing)
        });
    }

    function _openPool(CLPoolManager manager, uint24 lpFee, int24 tickSpacing) internal returns (PoolKey memory key) {
        key = _key(manager, lpFee, tickSpacing);
        manager.initialize(key, uint160(FixedPoint96.Q96));
    }
}
