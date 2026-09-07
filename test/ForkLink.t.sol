// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {ProtocolFeeLibrary} from "infinity-core/src/libraries/ProtocolFeeLibrary.sol";
import {CLQuoter} from "infinity-periphery/src/pool-cl/lens/CLQuoter.sol";
import {UniversalRouter} from "infinity-universal-router/src/UniversalRouter.sol";

/// @notice M0 gate. Proves this repo links against all three Infinity forks and that the
/// toolchain assumptions the plan rests on actually hold, so M1 does not discover them on a
/// live deploy. Everything here is compile-time or a two-line runtime probe; it is meant to
/// stay cheap enough to run on every PR.
contract ForkLinkTest is Test {
    Vault internal vault;
    CLPoolManager internal clPoolManager;
    BinPoolManager internal binPoolManager;

    function setUp() public {
        vault = new Vault();
        clPoolManager = new CLPoolManager(vault);
        binPoolManager = new BinPoolManager(vault);
        vault.registerApp(address(clPoolManager));
        vault.registerApp(address(binPoolManager));
    }

    /// @dev Infinity's flash accounting is transient storage. Injective sets CancunTime = 0
    /// and TSTORE/TLOAD were probed on 1439 and 1776, but if foundry.toml ever slipped off
    /// `cancun` we would ship contracts that cannot lock the vault.
    function test_transientStorageIsAvailable() public {
        uint256 slot = 0x1234;
        uint256 read;
        assembly ("memory-safe") {
            tstore(slot, 0xc0ffee)
            read := tload(slot)
        }
        assertEq(read, 0xc0ffee, "TSTORE/TLOAD unavailable: evm_version is not cancun");
    }

    function test_forksAreLinkedAndWired() public view {
        assertEq(address(clPoolManager.vault()), address(vault));
        assertEq(address(binPoolManager.vault()), address(vault));
        assertTrue(type(CLQuoter).creationCode.length > 0, "periphery not linked");
        assertTrue(type(UniversalRouter).creationCode.length > 0, "universal router not linked");
    }

    /// @dev The whole fee model (plan §4) assumes Infinity caps the protocol fee at 0.4% per
    /// direction and that 0.33 of the total fee stays under it on every tier we ship. If an
    /// upstream bump moved MAX_PROTOCOL_FEE, the tier table is wrong and this fails first.
    function test_protocolFeeCapCoversEveryChoiceTier() public pure {
        uint24[4] memory totalFeeTiers = [uint24(100), 500, 3000, 10_000]; // 0.01 / 0.05 / 0.3 / 1%
        assertEq(ProtocolFeeLibrary.MAX_PROTOCOL_FEE, 4000, "MAX_PROTOCOL_FEE moved: re-check plan tier table");

        for (uint256 i = 0; i < totalFeeTiers.length; i++) {
            // Choice takes 33% of the total fee; the rest is the LP fee in the PoolKey.
            uint24 protocolFee = uint24((uint256(totalFeeTiers[i]) * 33) / 100);
            assertLe(protocolFee, ProtocolFeeLibrary.MAX_PROTOCOL_FEE, "tier exceeds the protocol fee cap");
        }
    }

    /// @dev Guards the constants every consumer hardcodes, on EVERY book rather than on
    /// testnet's alone. This test used to read `injective_testnet.json` by name, which meant
    /// it silently stopped covering the deployment the moment a second book existed
    /// (MAINNET_READINESS C5) - the one moment its coverage mattered most. Both books are
    /// named here, and each is checked against the chain id its own filename claims.
    ///
    /// Permit2, wINJ and the Arachnid CREATE2 deployer are canonical at the SAME address on
    /// 1439 and 1776 - all three were read off both chains - so a book that disagrees has a
    /// typo, not a different deployment.
    function test_everyAddressBookMatchesChainConstants() public view {
        _assertBookConstants("injective_testnet", 1439);
        _assertBookConstants("injective_mainnet", 1776);
    }

    function _assertBookConstants(string memory network, uint256 chainId) internal view {
        string memory book = vm.readFile(string.concat("deployments/", network, ".json"));

        assertEq(vm.parseJsonUint(book, ".chainId"), chainId, string.concat(network, ": wrong chainId"));
        assertEq(
            vm.parseJsonString(book, ".network"), network, string.concat(network, ": name disagrees with filename")
        );
        assertEq(
            vm.parseJsonAddress(book, ".external.permit2"),
            0x000000000022D473030F116dDEE9F6B43aC78BA3,
            "permit2 is canonical on Injective; nothing to deploy"
        );
        assertEq(vm.parseJsonAddress(book, ".external.wINJ"), 0x0000000088827d2d103ee2d9A6b781773AE03FfB);
        assertEq(vm.parseJsonAddress(book, ".external.arachnidCreate2"), 0x4e59b44847b379578588920cA78FbF26c0B4956C);
    }

    /// @dev The two numbers that are decisions rather than facts, asserted so that changing
    /// either is a visible diff in a test rather than a quiet edit to a JSON file.
    /// CHOICE_V2_MAINNET_OPS.md §8, settled 2026-09-07: 3-of-5 on hardware wallets, 24 hours.
    /// 🔴 The delay is also the UNPAUSE latency - unpausePoolManager is onlyOwner and the
    /// timelock is the owner - so lowering it is a security decision in both directions.
    function test_mainnetGovernanceNumbersAreTheDecidedOnes() public view {
        string memory book = vm.readFile("deployments/injective_mainnet.json");
        assertEq(vm.parseJsonUint(book, ".governance.timelockMinDelay"), 86_400, "mainnet timelock delay is 24h");
        assertEq(vm.parseJsonUint(book, ".governance.safeThreshold"), 3, "mainnet Safe is 3-of-5");
    }
}
