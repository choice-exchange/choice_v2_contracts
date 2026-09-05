// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";

/**
 * The last step of every deploy, and the only one that fails loudly if the deploy is not
 * actually finished.
 *
 * `02_DeployFeeControllers` deploys the fee controllers through CREATE3, so each constructor
 * sees the factory's one-shot proxy child as `msg.sender` and `Ownable(msg.sender)` makes that
 * child the owner. The backrun payload calls `transferOwnership(timelock)` - but
 * `ProtocolFeeController` is `Ownable2Step`, so that only sets `pendingOwner`. Until the
 * timelock calls `acceptOwnership`, the controller is owned by a proxy child that can never be
 * called again: a live contract holding protocol revenue with nobody able to change the
 * treasury, the split or the sink. That is D2's brick one level down.
 *
 * Nothing enforced that. The comment in script 02 pointed at "script 04", which is
 * `04_SeedPool`; the accept step existed only as something somebody remembered to do. It was
 * done correctly on testnet, by hand. On mainnet it will be done through a Safe, under time
 * pressure, and nothing fails if it is skipped until somebody needs to change the treasury.
 *
 * This script is read-only. It broadcasts nothing and holds no key: it reads the address book,
 * checks every contract that should be behind the timelock, and prints the Safe -> timelock
 * calldata for anything still outstanding. It exits non-zero if any of them is.
 *
 *   NETWORK=injective_testnet forge script script/08_VerifyOwnership.s.sol:VerifyOwnership \
 *       -vv --rpc-url $RPC_URL
 *
 * A key absent from the book is SKIPPED rather than failed, so the script is runnable part way
 * through a deploy. A key that is present must be correct.
 */
contract VerifyOwnership is BaseScript {
    /// @dev `acceptOwnership()`.
    bytes4 internal constant ACCEPT_OWNERSHIP = 0x79ba5097;

    uint256 internal constant MAINNET_CHAIN_ID = 1776;

    /// @dev The timelock delay is the ONLY barrier between a compromised Safe and every
    /// contract here: the executor set is `[address(0)]`, the open role, so once an operation
    /// has sat out its delay anybody can execute it. Testnet runs at 60 seconds, which is not
    /// a barrier; mainnet must not.
    uint256 internal constant MAINNET_MIN_TIMELOCK_DELAY = 24 hours;

    address internal timelock;
    uint256 internal delay;
    uint256 internal chainId;

    uint256 internal checked;
    uint256 internal skipped;
    uint256 internal outstanding;
    uint256 internal wrong;

    function run() public {
        timelock = readAddress("governance.timelock");
        requireCode("timelock", timelock);
        delay = readUint("governance.timelockMinDelay");
        chainId = readUint("chainId");

        console.log("timelock:", timelock);
        console.log("chain:   ", chainId);
        console.log("");

        console.log("Behind the timelock directly");
        string[11] memory timelockOwned = [
            "choice.clFeeController",
            "choice.binFeeController",
            "choice.infinitySettler",
            "choice.positionLocker",
            "choice.launchPoolGuardHook",
            "choice.choiceRouter",
            "choice.exchangeSubaccountBurnSink",
            "infinity.vault",
            "infinity.universalRouter",
            "infinity.clPoolManagerOwner",
            "infinity.binPoolManagerOwner"
        ];
        for (uint256 i; i < timelockOwned.length; ++i) {
            _requireOwnedBy(timelockOwned[i], timelock, "the timelock");
        }

        // Safe -> Timelock -> PoolManagerOwner -> PoolManager (script 03). The owner contracts
        // carry `PausableRole`, which is why the pool managers sit behind them rather than
        // behind the timelock directly - an emergency pause should not need the full delay.
        console.log("");
        console.log("Behind their PoolManagerOwner contracts");
        _requireOwnedByBookEntry("infinity.clPoolManager", "infinity.clPoolManagerOwner");
        _requireOwnedByBookEntry("infinity.binPoolManager", "infinity.binPoolManagerOwner");

        console.log("");
        _checkCreate3Factory();

        console.log("");
        _checkTimelockDelay();

        _report();
    }

    // -------------------------------------------------------------------------------------

    /// @dev Owned outright, or pending acceptance by the expected owner - which is a step
    /// somebody still has to take, not a pass.
    function _requireOwnedBy(string memory key, address expected, string memory expectedName) internal {
        address at = readAddressOrZero(key);
        if (at == address(0) || at.code.length == 0) {
            skipped++;
            console.log(string.concat("  [skip] ", key, " is not in the book yet"));
            return;
        }
        checked++;

        (bool hasOwner, address current) = _owner(at);
        if (!hasOwner) {
            wrong++;
            console.log(string.concat("  [WRONG] ", key, " has no owner() - is this the right address?"));
            return;
        }
        if (current == expected) {
            console.log(string.concat("  [ok]    ", key));
            return;
        }

        (bool hasPending, address pending) = _pendingOwner(at);
        if (hasPending && pending == expected) {
            outstanding++;
            console.log(string.concat("  [TODO]  ", key, " is still only PENDING for ", expectedName));
            console.log(string.concat("            at ", vm.toString(at), ", owned by ", vm.toString(current)));
            _printAcceptPayload(at);
            return;
        }

        wrong++;
        console.log(string.concat("  [WRONG] ", key, " is not owned by ", expectedName));
        console.log(string.concat("            owner ", vm.toString(current), ", expected ", vm.toString(expected)));
    }

    function _requireOwnedByBookEntry(string memory key, string memory ownerKey) internal {
        address expected = readAddressOrZero(ownerKey);
        if (expected == address(0)) {
            skipped++;
            console.log(string.concat("  [skip] ", ownerKey, " is not in the book yet"));
            return;
        }
        _requireOwnedBy(key, expected, ownerKey);
    }

    /// @dev The Safe cannot call `acceptOwnership` itself - the pending owner is the TIMELOCK,
    /// so it has to go through schedule/execute. Both payloads are printed because getting the
    /// second one's arguments to match the first is the whole trick with a TimelockController.
    function _printAcceptPayload(address target) internal view {
        bytes memory accept = abi.encodeWithSelector(ACCEPT_OWNERSHIP);
        console.log(
            string.concat(
                "            1. Safe -> timelock.schedule: ",
                vm.toString(
                    abi.encodeWithSignature(
                        "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
                        target,
                        uint256(0),
                        accept,
                        bytes32(0),
                        bytes32(0),
                        delay
                    )
                )
            )
        );
        console.log(
            string.concat(
                "            2. after ",
                vm.toString(delay),
                "s, anyone -> timelock.execute: ",
                vm.toString(
                    abi.encodeWithSignature(
                        "execute(address,uint256,bytes,bytes32,bytes32)",
                        target,
                        uint256(0),
                        accept,
                        bytes32(0),
                        bytes32(0)
                    )
                )
            )
        );
    }

    /// @dev `Create3Factory` derives its address from the SALT ALONE - it is not namespaced by
    /// `msg.sender` - and the salts here are public strings baked into these scripts. So any
    /// whitelisted address can deploy any bytecode at any salt not yet used, and the locker and
    /// the guard hook are both constructed pointing at the settler's PREDICTED address. That
    /// makes the factory's owner a trust root the size of the timelock for as long as unused
    /// salts remain. It should not be an EOA on mainnet.
    function _checkCreate3Factory() internal {
        console.log("CREATE3 factory");
        address factory = readAddressOrZero("governance.create3Factory");
        if (factory == address(0) || factory.code.length == 0) {
            skipped++;
            console.log("  [skip] governance.create3Factory is not in the book yet");
            return;
        }
        (bool hasOwner, address owner_) = _owner(factory);
        if (!hasOwner) {
            console.log("  [WARN] the factory has no owner() - cannot check its whitelist authority");
            return;
        }
        if (owner_.code.length != 0) {
            console.log(string.concat("  [ok]    owned by a contract: ", vm.toString(owner_)));
            return;
        }
        if (chainId == MAINNET_CHAIN_ID) {
            wrong++;
            console.log(string.concat("  [WRONG] owned by an EOA on mainnet: ", vm.toString(owner_)));
            console.log("            Salts are not namespaced by sender, so this key can still mint");
            console.log("            any predicted address in the deployment. Move it to the Safe and");
            console.log("            revoke the deploy whitelist once the last salt is consumed.");
            return;
        }
        console.log(string.concat("  [WARN]  owned by an EOA: ", vm.toString(owner_), " (fails on mainnet)"));
    }

    function _checkTimelockDelay() internal {
        console.log("Timelock delay");
        if (chainId != MAINNET_CHAIN_ID) {
            console.log(string.concat("  [warn]  ", vm.toString(delay), "s - mainnet requires 24h or more"));
            return;
        }
        if (delay < MAINNET_MIN_TIMELOCK_DELAY) {
            wrong++;
            console.log(string.concat("  [WRONG] ", vm.toString(delay), "s is below the mainnet floor of 24h"));
            console.log("            The executor role is open, so the delay is the only barrier there is.");
            return;
        }
        console.log(string.concat("  [ok]    ", vm.toString(delay), "s"));
    }

    function _report() internal view {
        console.log("");
        console.log(string.concat("checked ", vm.toString(checked), ", skipped ", vm.toString(skipped)));
        if (outstanding > 0) {
            console.log(string.concat(vm.toString(outstanding), " OUTSTANDING acceptOwnership call(s) - see above"));
        }
        if (wrong > 0) {
            console.log(string.concat(vm.toString(wrong), " contract(s) behind the wrong owner"));
        }
        require(outstanding == 0, "deploy is unfinished: an acceptOwnership is still outstanding");
        require(wrong == 0, "ownership is wrong somewhere - see the log above");
        console.log("Ownership is where it should be.");
    }

    // -------------------------------------------------------------------------------------

    /// @dev Staticcalls rather than interface calls, because the set spans OpenZeppelin's
    /// `Ownable2Step`, infinity-core's own one-step `Ownable`, and contracts with no owner at
    /// all - and an absent `pendingOwner()` has to read as "one-step", not as a failure.
    function _owner(address target) internal view returns (bool has, address owner_) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || ret.length != 32) return (false, address(0));
        return (true, abi.decode(ret, (address)));
    }

    function _pendingOwner(address target) internal view returns (bool has, address pending) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("pendingOwner()"));
        if (!ok || ret.length != 32) return (false, address(0));
        return (true, abi.decode(ret, (address)));
    }
}
