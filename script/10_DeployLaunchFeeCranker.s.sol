// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";

import {BuybackBurnSink} from "../src/fees/BuybackBurnSink.sol";
import {ILaunchPositionLocker} from "../src/interfaces/ILaunchPositionLocker.sol";
import {LaunchFeeCranker} from "../src/launchpad/LaunchFeeCranker.sol";
import {BaseScript} from "./BaseScript.sol";

/**
 * The one permissionless call that takes a graduated launch's LP fees to the burn (plan A6),
 * deployed once per LOCKER GENERATION (plan A9).
 *
 * Trading a graduated pool accrues fees inside a locked position and nothing else happens.
 * Turning them into a destroyed burn token was three calls - `collect`, `claim` per currency, then
 * the sink's own leg - all permissionless by design, and named to nobody. This deploys the helper
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
 * concrete `BuybackBurnSink` type rather than an interface copy of it. ⚠️ Since A9 that is
 * "bump BOTH instances' salts and run this script twice", once per `CRANKER_LOCKER_KEY`.
 *
 * ## 🔑 One cranker per locker generation, and why it is a second instance rather than a branch
 *
 * The cranker's `LOCKER` is immutable, so an instance reaches exactly one generation's launches
 * and the other's are invisible to it. That is not theoretical: the 1.0.0 locker holds launches
 * 13-17, **the burn token's own launch among them**, and for as long as one cranker existed those
 * fees had nothing scheduled to move them while the keeper's auto-crank ran every fifteen
 * minutes against the 1.1.0 locker and reported a healthy pass every time. Nothing was broken
 * and nothing said anything.
 *
 * The answer is a SECOND INSTANCE, never a branch inside the contract. A cranker that sniffed
 * which generation it was talking to would be the "five copies of what is current" problem in a
 * new place, and A6's own header rejected it in advance. It costs nothing to avoid: locker 1.0.0
 * has no `claim` at all (it PUSHES on `collect`) and the cranker's `try` around that leg already
 * tolerates the missing selector, so the same bytecode serves both generations unchanged.
 *
 *   CRANKER_LOCKER_KEY=choice.positionLocker       (default) -> book choice.launchFeeCranker
 *   CRANKER_LOCKER_KEY=choice.positionLockerLegacy           -> book choice.launchFeeCrankerLegacy
 *
 * 🔴 That variable names a BOOK KEY, not an address - the same rule `quoteRouteAssetKeys`
 * follows, so each locker's address still lives in exactly one place. And an unrecognised key
 * REVERTS rather than deriving a salt from whatever string it was handed: a typo that hashed to
 * a fresh salt would deploy a third cranker at an address this book never records, and the
 * keeper would go on cranking the two it knows about while a locker's fees sat still. That is
 * precisely the failure A9 exists to fix, reintroduced one layer up.
 *
 * forge script script/10_DeployLaunchFeeCranker.s.sol:DeployLaunchFeeCranker -vv \
 *     --rpc-url $RPC_URL --broadcast
 *
 * No --slow: Injective never serves a receipt, so --slow strands the run after its first tx.
 * No --resume, ever. Re-run instead; every step below is idempotent.
 */
contract DeployLaunchFeeCranker is BaseScript {
    string internal constant LIVE_LOCKER_KEY = "choice.positionLocker";
    string internal constant LEGACY_LOCKER_KEY = "choice.positionLockerLegacy";

    /// 2.1.0 is the 2026-09-11 core cutover: the SAME bytecode as 2.0.0 with a new `LOCKER`
    /// constructor argument (locker 1.3.0). A cranker's locker is immutable, so a new locker
    /// generation forces a new cranker instance (the A9 rule) even when nothing in this file
    /// changes - and a CREATE3 salt hashes the whole payload, arguments included, so it MUST move
    /// with the arguments or `factory.deploy` lands on 2.0.0's address and reverts. 2.0.0 stays
    /// live, bound to locker 1.2.0, and the keeper drives exactly one of them at a time.
    ///
    /// 2.0.0 added the timelock-owned `setSink` / `setLocker`, so the constructor took an owner
    /// and the creation code changed.
    ///
    /// ✅ **And 2.0.0 was the LAST time the salt has to move for a sink swap.** Bumping it used to
    /// be mandatory whenever the sink's own salt moved, because `SINK` was immutable; from 2.0.0
    /// that is a `setSink` call behind the timelock. Bump this only when THIS contract's code or
    /// its constructor arguments change.
    bytes32 internal constant CRANKER_SALT = keccak256("CHOICE-V2/LaunchFeeCranker/2.1.0");

    /// The A9 instance, bound to the 1.0.0 PUSH locker. A DISTINCT salt, deliberately spelled
    /// out rather than derived from the locker key: the live instance is already deployed at the
    /// address the constant above names, and a scheme that computed both would be one refactor
    /// away from moving it.
    bytes32 internal constant CRANKER_LEGACY_SALT = keccak256("CHOICE-V2/LaunchFeeCrankerLegacy/2.0.0");

    function run() public {
        string memory lockerKey = vm.envOr("CRANKER_LOCKER_KEY", LIVE_LOCKER_KEY);
        (bytes32 salt, string memory bookKey) = _instanceFor(lockerKey);

        Create3Factory factory = Create3Factory(readAddress("governance.create3Factory"));
        address locker = readAddress(lockerKey);
        address sink = readAddress("choice.buybackBurnSink");
        address timelock = readAddress("governance.timelock");

        requireCode("positionLocker", locker);
        requireCode("buybackBurnSink", sink);
        requireCode("timelock", timelock);

        console.log("locker key       :", lockerKey);
        console.log("locker           :", locker);
        console.log("book key         :", bookKey);

        address cranker = factory.computeAddress(salt);
        console.log("LaunchFeeCranker ->", cranker);

        if (cranker.code.length == 0) {
            // 🔴 The hash the factory checks is of the WHOLE payload, constructor arguments
            // included - hashing the bare `creationCode` fails with `CreationCodeHashMismatch`.
            bytes memory payload = abi.encodePacked(
                type(LaunchFeeCranker).creationCode,
                abi.encode(ILaunchPositionLocker(locker), BuybackBurnSink(payable(sink)), timelock)
            );

            vm.startBroadcast(deployerKey());
            address deployed = factory.deploy(salt, payload, keccak256(payload), 0, "", 0);
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
        // ⚠️ And against the locker THIS RUN was asked for, not against a fixed key: with two
        // instances alive, checking the live locker unconditionally would pass the legacy
        // instance's deploy for the wrong reason and then fail it for a real one.
        require(address(c.LOCKER()) == locker, "cranker collects from a different locker than the book names");
        // 🔴 The owner assertion, and it is the one that makes 2.0.0's setters defensible at all.
        // `setSink` and `setLocker` behind a 24-hour timelock is a bounded trade (see the
        // contract's header); the same two functions behind an EOA are a mutable burn destination
        // in one hand, which is exactly what plan A6 refused. An instance owned by anything but
        // the timelock must not be adopted, and this is where a deploy finds out.
        require(c.owner() == timelock, "cranker is not owned by the timelock");

        // The sink must be able to resolve this locker's launches, or every crank collects and
        // claims and then finds no route. It is a `setLockers` call on the sink, not here.
        require(
            BuybackBurnSink(payable(sink)).isLocker(locker),
            "the sink does not list this locker - run 09 and make the setLockers call first"
        );

        writeAddress(bookKey, cranker);

        console.log("");
        if (c.feedIsWired()) {
            console.log("  [ok]   this locker's launchpadTreasury is the sink - a crank burns");
        } else {
            console.log("  [TODO] this locker's launchpadTreasury is NOT the sink (plan B6)");
            console.log("           a crank will collect and pay, and nothing will burn");
            _printTimelockPayloads(locker, abi.encodeWithSignature("setLaunchpadTreasury(address)", sink));
        }
        console.log("");
        console.log("  Nothing else to configure. crank(launchId) is permissionless;");
        console.log("  crankMany(uint256[]) is the keeper shape.");
        console.log("  [!] The keeper's CRANK_CRANKER is a SET - add this address to it, or the");
        console.log("     instance exists and still nothing calls it.");
    }

    /// @dev The book key -> (salt, book entry) table. Deliberately exhaustive and deliberately
    /// reverting: see the header. Compared by hash because Solidity cannot compare strings.
    function _instanceFor(string memory lockerKey) internal pure returns (bytes32 salt, string memory bookKey) {
        bytes32 h = keccak256(bytes(lockerKey));
        if (h == keccak256(bytes(LIVE_LOCKER_KEY))) return (CRANKER_SALT, "choice.launchFeeCranker");
        if (h == keccak256(bytes(LEGACY_LOCKER_KEY))) return (CRANKER_LEGACY_SALT, "choice.launchFeeCrankerLegacy");
        revert(
            string.concat(
                "CRANKER_LOCKER_KEY=",
                lockerKey,
                " is not a locker this script knows. Use ",
                LIVE_LOCKER_KEY,
                " or ",
                LEGACY_LOCKER_KEY,
                " - a salt derived from an unknown key would deploy a cranker the book never records."
            )
        );
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
