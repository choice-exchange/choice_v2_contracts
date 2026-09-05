// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ChoiceRouter} from "../src/router/ChoiceRouter.sol";
import {BaseScript} from "./BaseScript.sol";

/**
 * M5 step 4: the cross-vault router.
 *
 * `ChoiceRouter` exists for routes that span TWO Infinity deployments - Choice's and Pumex's -
 * under a single end-to-end `minimumReceive`. A route inside one deployment must never come
 * here; `INFI_SWAP` already runs a whole split, multi-hop route in one vault lock, and
 * `execute` REVERTS with `NotCrossVault` rather than let a caller pay for the worse path.
 *
 * 🔴 On a network where only ONE vault exists, that is every route. This deploys the contract
 * and allowlists the vaults the address book knows about; on `injective_testnet` that is
 * Choice's vault alone, so the router is deployed and owned but has nothing to route across
 * until a second deployment is registered with `setVault` (timelock). That is the honest
 * configuration - allowlisting a vault that does not exist on this chain would be a lie the
 * frontend could act on.
 *
 * Owned by the TIMELOCK from construction: `Ownable(_owner)` takes the owner as an argument,
 * so there is no `transferOwnership` backrun and therefore no `Ownable2Step` pending-owner
 * window for a CREATE3 proxy child to strand (the D2 brick, one level down).
 *
 * forge script script/07_DeployChoiceRouter.s.sol:DeployChoiceRouter -vv \
 *     --rpc-url $RPC_URL --broadcast --gas-limit 15000000
 *
 * No --slow: Injective never serves a receipt, so --slow strands the run after its first tx.
 * No --resume, ever. Re-run instead; the step below is idempotent.
 */
contract DeployChoiceRouter is BaseScript {
    bytes32 internal constant ROUTER_SALT = keccak256("CHOICE-V2/ChoiceRouter/1.0.0");

    function run() public {
        Create3Factory factory = Create3Factory(readAddress("governance.create3Factory"));
        address timelock = readAddress("governance.timelock");
        address permit2 = readAddress("external.permit2");
        address vault = readAddress("infinity.vault");

        requireCode("timelock", timelock);
        requireCode("permit2", permit2);
        requireCode("vault", vault);

        // Every vault this network actually has. A second Infinity deployment (Pumex on
        // mainnet) is added by the owner afterwards, because its address is not ours to
        // record in this book.
        IVault[] memory vaults = new IVault[](1);
        vaults[0] = IVault(vault);

        address at = factory.computeAddress(ROUTER_SALT);
        console.log("[predicted] choiceRouter:", at);

        vm.startBroadcast(deployerKey());
        if (at.code.length > 0) {
            console.log("  already deployed, skipping:", at);
        } else {
            bytes memory creationCode = abi.encodePacked(
                type(ChoiceRouter).creationCode, abi.encode(timelock, IAllowanceTransfer(permit2), vaults)
            );
            address deployed = factory.deploy(ROUTER_SALT, creationCode, keccak256(creationCode), 0, "", 0);
            require(deployed == at, "create3 address mismatch");
            console.log("  deployed:", deployed);
        }
        vm.stopBroadcast();

        require(ChoiceRouter(payable(at)).owner() == timelock, "router is not owned by the timelock");
        require(address(ChoiceRouter(payable(at)).PERMIT2()) == permit2, "router has the wrong permit2");
        require(ChoiceRouter(payable(at)).allowedVault(vault), "router does not allow this network's vault");

        writeAddress("choice.choiceRouter", at);

        console.log("");
        console.log("  Cross-vault only. Until a SECOND vault is allowlisted, every route on");
        console.log("  this chain reverts NotCrossVault by design - single-deployment routes go");
        console.log("  straight to the UniversalRouter.");
    }
}
