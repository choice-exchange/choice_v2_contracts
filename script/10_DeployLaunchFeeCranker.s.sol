// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";

import {BuybackBurnSink} from "../src/fees/BuybackBurnSink.sol";
import {ILaunchPositionLocker} from "../src/interfaces/ILaunchPositionLocker.sol";
import {LaunchFeeCranker} from "../src/launchpad/LaunchFeeCranker.sol";
import {BaseScript} from "./BaseScript.sol";

/**
 * The one permissionless call that takes a graduated launch's LP fees to the burn (plan A6).
 *
 * Trading a graduated pool accrues fees inside a locked position and nothing else happens.
 * Turning them into destroyed SPROUT was three calls - `collect`, `claim` per currency, then the
 * sink's own leg - all permissionless by design, and named to nobody. This deploys the helper
 * that does all of it for a launch in one transaction.
 *
 * It takes no arguments a human has to get right: the locker and the sink come out of the
 * address book, and everything else (the position manager, the quote asset, the burn token) is
 * READ off those two in the constructor. There is nothing to configure afterwards - no owner, no
 * setters, no wiring step this script has to print.
 *
 * 🔴 **Its sink reference is immutable, and it calls `convert(Currency,uint256)`, which exists
 * only from sink 1.2.0. A sink redeploy is therefore ALWAYS a cranker redeploy** - bump both
 * salts, run 09 then 10, and check `cranker.SINK()` afterwards. That is the A3 lockstep rule
 * applied forwards; the compiler enforces the ABI half of it, because this contract holds the
 * concrete `BuybackBurnSink` type rather than an interface copy of it.
 *
 * ⚠️ It is deployed against the LIVE locker. Locker 1.0.0 has no `claim` at all (it pushes on
 * `collect`), and the cranker's `try` around that leg means an instance pointed at it would
 * still work - but this script deploys ONE, at `choice.positionLocker`. If the older locker's
 * launches are ever worth cranking, deploy a second instance with a different salt rather than
 * teaching this one to sniff which generation it is talking to.
 *
 * forge script script/10_DeployLaunchFeeCranker.s.sol:DeployLaunchFeeCranker -vv \
 *     --rpc-url $RPC_URL --broadcast
 *
 * No --slow: Injective never serves a receipt, so --slow strands the run after its first tx.
 * No --resume, ever. Re-run instead; every step below is idempotent.
 */
contract DeployLaunchFeeCranker is BaseScript {
    /// 1.0.0 is plan A6. 🔴 Bump this whenever the sink's salt moves - see the header.
    bytes32 internal constant CRANKER_SALT = keccak256("CHOICE-V2/LaunchFeeCranker/1.0.0");

    function run() public {
        Create3Factory factory = Create3Factory(readAddress("governance.create3Factory"));
        address locker = readAddress("choice.positionLocker");
        address sink = readAddress("choice.buybackBurnSink");

        requireCode("positionLocker", locker);
        requireCode("buybackBurnSink", sink);

        address cranker = factory.computeAddress(CRANKER_SALT);
        console.log("LaunchFeeCranker 1.0.0 ->", cranker);

        if (cranker.code.length == 0) {
            // 🔴 The hash the factory checks is of the WHOLE payload, constructor arguments
            // included - hashing the bare `creationCode` fails with `CreationCodeHashMismatch`.
            bytes memory payload = abi.encodePacked(
                type(LaunchFeeCranker).creationCode,
                abi.encode(ILaunchPositionLocker(locker), BuybackBurnSink(payable(sink)))
            );

            vm.startBroadcast(deployerKey());
            address deployed = factory.deploy(CRANKER_SALT, payload, keccak256(payload), 0, "", 0);
            vm.stopBroadcast();
            require(deployed == cranker, "create3 address prediction is wrong");
        } else {
            console.log("  already deployed - checking its wiring");
        }

        LaunchFeeCranker c = LaunchFeeCranker(cranker);

        // 🔴 The lockstep assertion, made where it can be read rather than left as a comment. A
        // cranker whose SINK is not the book's is one built against a superseded sink, and its
        // `convert` calls would land on a contract that no longer has that selector - the exact
        // shape that reverted with empty returndata and wedged a graduation on 2026-09-06.
        require(address(c.SINK()) == sink, "cranker drives a different sink than the address book names");
        require(address(c.LOCKER()) == locker, "cranker collects from a different locker than the book names");

        // The sink must be able to resolve this locker's launches, or every crank collects and
        // claims and then finds no route. It is a `setLockers` call on the sink, not here.
        require(
            BuybackBurnSink(payable(sink)).isLocker(locker),
            "the sink does not list this locker - run 09 and make the setLockers call first"
        );

        writeAddress("choice.launchFeeCranker", cranker);

        console.log("");
        if (c.feedIsWired()) {
            console.log("  [ok]   positionLocker.launchpadTreasury is the sink - a crank burns");
        } else {
            console.log("  [TODO] positionLocker.launchpadTreasury is NOT the sink (plan B6)");
            console.log("           a crank will collect and pay, and nothing will burn");
            _printTimelockPayloads(
                locker, abi.encodeWithSignature("setLaunchpadTreasury(address)", sink)
            );
        }
        console.log("");
        console.log("  Nothing else to configure. crank(launchId) is permissionless;");
        console.log("  crankMany(uint256[]) is the keeper shape.");
    }

    /// @dev Both halves, because matching `execute`'s arguments to the `schedule` they came
    /// from is the whole trick with a `TimelockController`.
    function _printTimelockPayloads(address target, bytes memory payload) internal view {
        uint256 delay = readUint("governance.timelockMinDelay");
        console.log(
            string.concat(
                "           1. Safe -> timelock.schedule: ",
                vm.toString(
                    abi.encodeWithSignature(
                        "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
                        target,
                        uint256(0),
                        payload,
                        bytes32(0),
                        bytes32(0),
                        delay
                    )
                )
            )
        );
        console.log(
            string.concat(
                "           2. after ",
                vm.toString(delay),
                "s, anyone -> timelock.execute: ",
                vm.toString(
                    abi.encodeWithSignature(
                        "execute(address,uint256,bytes,bytes32,bytes32)",
                        target,
                        uint256(0),
                        payload,
                        bytes32(0),
                        bytes32(0)
                    )
                )
            )
        );
    }
}
