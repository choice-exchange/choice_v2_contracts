// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {ProtocolFeeLibrary} from "infinity-core/src/libraries/ProtocolFeeLibrary.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ChoiceFeeController} from "../src/fees/ChoiceFeeController.sol";
import {IBurnSink} from "../src/interfaces/IBurnSink.sol";

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

    Vault internal vault;
    CLPoolManager internal poolManager;
    ChoiceFeeController internal controller;
    RecordingBurnSink internal sink;
    MockERC20 internal token;

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

    function test_harvestRevertsWhenThereIsNothingToCollect() public {
        vm.expectRevert(ChoiceFeeController.NothingToHarvest.selector);
        controller.harvest(Currency.wrap(address(token)));
    }

    /// @dev A broken sink must fail the whole harvest, not quietly leave the burn share in
    /// the controller where it reads as revenue nobody is watching.
    function test_harvestRevertsIfTheBurnSinkReverts() public {
        RevertingBurnSink broken = new RevertingBurnSink();
        vm.prank(TIMELOCK);
        controller.setBurnSink(broken);

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
}
