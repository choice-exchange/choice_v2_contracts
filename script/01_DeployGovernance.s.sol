// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {BaseScript} from "./BaseScript.sol";
import {ISafe, ISafeProxyFactory} from "./interfaces/ISafe.sol";

/**
 * M0.4 - the root of the ownership tree (plan D13).
 *
 *   Safe (m-of-n signers)  ->  TimelockController  ->  everything else
 *
 * Deploys both in one broadcast, because the timelock's proposer set is the Safe and the Safe
 * address is only known once its proxy exists.
 *
 * forge script script/01_DeployGovernance.s.sol:DeployGovernance -vvv \
 *     --rpc-url $RPC_URL --broadcast --slow
 *
 * Never --resume: Injective returns a null receipt for a mined tx, so forge will offer to
 * replay work that already landed. Confirm with eth_getCode and re-read the address book.
 */
contract DeployGovernance is BaseScript {
    /// @dev CREATE3 salt, so the timelock lands on the same address on testnet and mainnet
    /// even though its constructor arguments (the Safe, the delay) differ between them.
    bytes32 internal constant TIMELOCK_SALT = keccak256("CHOICE-V2/TimelockController/1.0.0");

    function run() public {
        address safeProxyFactory = readAddress("external.safeProxyFactory");
        address safeSingleton = readAddress("external.safeSingletonL2");
        address safeFallbackHandler = readAddress("external.safeFallbackHandler");
        Create3Factory factory = Create3Factory(readAddress("governance.create3Factory"));

        requireCode("safeProxyFactory", safeProxyFactory);
        requireCode("safeSingletonL2", safeSingleton);
        requireCode("safeFallbackHandler", safeFallbackHandler);
        requireCode("create3Factory", address(factory));

        address[] memory signers = readAddressArray("governance.safeSigners");
        uint256 threshold = readUint("governance.safeThreshold");
        uint256 saltNonce = readUint("governance.safeSaltNonce");
        uint256 minDelay = readUint("governance.timelockMinDelay");
        require(threshold > 0 && threshold <= signers.length, "bad Safe threshold");

        uint256 pk = deployerKey();
        address deployer = vm.addr(pk);
        require(
            factory.isUserWhitelisted(deployer), "deployer not whitelisted on the create3 factory: setWhitelistUser"
        );

        console.log("deployer:", deployer);
        console.log("Safe threshold / signers:", threshold, signers.length);
        console.log("timelock minDelay (s):", minDelay);

        // Both legs below are skipped when the contract is already there. This is not
        // defensive padding: Injective answers `eth_getTransactionReceipt` with null for a tx
        // it has already mined, so a broadcast routinely reports failure after the work
        // landed. `--resume` would then re-send it, and re-sending `createProxyWithNonce` with
        // the same salt reverts on the CREATE2 collision, leaving the run stuck. Re-running
        // the script from the top is the recovery path, so the script has to be idempotent.
        address safe = readAddressOrZero("governance.safe");
        address timelock = factory.computeAddress(TIMELOCK_SALT);

        vm.startBroadcast(pk);

        // --- Safe -------------------------------------------------------------------------
        // The SafeL2 singleton rather than the plain one: Injective has no hosted Safe
        // transaction service, so the extra SafeMultiSigTransaction event is the only way our
        // own indexer can reconstruct what the Safe did.
        if (safe.code.length > 0) {
            console.log("Safe already deployed, skipping:", safe);
        } else {
            bytes memory initializer = abi.encodeCall(
                ISafe.setup,
                (
                    signers,
                    threshold,
                    address(0), // no setup delegatecall
                    "",
                    safeFallbackHandler,
                    address(0), // no payment token
                    0,
                    payable(address(0))
                )
            );
            safe = ISafeProxyFactory(safeProxyFactory).createProxyWithNonce(safeSingleton, initializer, saltNonce);
            console.log("Safe deployed at", safe);
        }

        // --- TimelockController -----------------------------------------------------------
        // Proposers also get CANCELLER_ROLE from the constructor, so the Safe can both
        // schedule and cancel. The executor set is [address(0)], which OpenZeppelin reads as
        // "open role": once an operation has sat out its delay, anybody may execute it, so a
        // scheduled action cannot be stranded by signers being unavailable. `admin` is
        // address(0), so nothing outside this shape can ever grant itself a role.
        if (timelock.code.length > 0) {
            console.log("TimelockController already deployed, skipping:", timelock);
        } else {
            address[] memory proposers = new address[](1);
            proposers[0] = safe;
            address[] memory executors = new address[](1);
            executors[0] = address(0);

            bytes memory creationCode = abi.encodePacked(
                type(TimelockController).creationCode, abi.encode(minDelay, proposers, executors, address(0))
            );
            address deployed = factory.deploy(TIMELOCK_SALT, creationCode, keccak256(creationCode), 0, new bytes(0), 0);
            require(deployed == timelock, "create3 address mismatch");
            console.log("TimelockController deployed at", deployed);
        }

        vm.stopBroadcast();

        writeAddress("governance.safe", safe);
        writeAddress("governance.timelock", timelock);
    }
}
