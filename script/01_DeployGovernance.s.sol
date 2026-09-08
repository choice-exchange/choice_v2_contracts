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
 *     --rpc-url $RPC_URL --broadcast --gas-limit 15000000
 *
 * ⛔ Never --slow, and this docstring used to say it. forge then waits for a receipt before
 * sending the next transaction, and this script sends TWO - so the Safe lands and the timelock
 * is never broadcast at all. Injective's testnet node has no hash index to find a receipt by,
 * and on mainnet the wait buys nothing this script needs.
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
        // Safe's own `setup` rejects both of these, but it rejects them halfway through a
        // broadcast that has already spent gas and, on a re-run, after the CREATE2 salt is
        // consumed. A book that names the same signer twice is a 2-of-3 that is really a
        // 2-of-2, which is exactly the kind of mistake that reads as fine in a diff.
        for (uint256 i; i < signers.length; ++i) {
            require(signers[i] != address(0), "a Safe signer is the zero address");
            for (uint256 j = i + 1; j < signers.length; ++j) {
                require(signers[i] != signers[j], "duplicate Safe signer");
            }
        }

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

        // 🔴 BEFORE the book is written, not after. Both legs above are skipped when the
        // address already has code, and neither asks WHAT is there - which is the hole this
        // closes. `Create3.addressOf(salt)` is not namespaced by `msg.sender`, so any address
        // whitelisted on the factory can place arbitrary code at this timelock's salt; the
        // Safe's proxy address is likewise a pure function of (singleton, initializer, nonce)
        // and the initializer is public. Adopting either would write an address this deployment
        // does not control into the file every other script, the frontend, the backend and the
        // launchpad read as the source of truth.
        //
        // Everything here is a view call on the deployed contracts, so it costs no gas and it
        // runs identically on a fresh deploy and on a re-run after a dropped receipt.
        _verifyGovernance(safe, timelock, signers, threshold, minDelay, deployer);

        writeAddress("governance.safe", safe);
        writeAddress("governance.timelock", timelock);
    }

    /// @dev The shape script 08 checks on every later run, asserted here at the one moment it
    /// can still be cheap to fix: nothing downstream exists yet.
    function _verifyGovernance(
        address safe,
        address timelock,
        address[] memory signers,
        uint256 threshold,
        uint256 minDelay,
        address deployer
    ) internal view {
        require(ISafe(safe).getThreshold() == threshold, "Safe threshold on chain is not the book's");
        address[] memory owners = ISafe(safe).getOwners();
        require(owners.length == signers.length, "Safe owner count on chain is not the book's");
        for (uint256 i; i < signers.length; ++i) {
            require(ISafe(safe).isOwner(signers[i]), "a book signer is not an owner of the Safe on chain");
        }

        TimelockController tl = TimelockController(payable(timelock));
        require(tl.getMinDelay() == minDelay, "timelock delay on chain is not the book's");
        require(tl.hasRole(tl.PROPOSER_ROLE(), safe), "the Safe is not a proposer on this timelock");
        require(tl.hasRole(tl.CANCELLER_ROLE(), safe), "the Safe is not a canceller on this timelock");
        // `executors = [address(0)]` is OpenZeppelin's open role, so a matured operation cannot
        // be stranded by absent signers. Deliberate, and therefore asserted.
        require(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "the executor role is not open");
        // `admin = address(0)` in the constructor leaves DEFAULT_ADMIN with the timelock alone.
        // Anything else holding it could grant itself any role and skip the delay entirely.
        require(!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), safe), "the Safe holds DEFAULT_ADMIN_ROLE");
        require(!tl.hasRole(tl.PROPOSER_ROLE(), deployer), "the deployer holds PROPOSER_ROLE");
        require(!tl.hasRole(tl.CANCELLER_ROLE(), deployer), "the deployer holds CANCELLER_ROLE");
        require(!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), deployer), "the deployer holds DEFAULT_ADMIN_ROLE");

        console.log("  governance verified: Safe owners/threshold and timelock roles/delay match the book");
    }
}
