// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";

interface IOwnable1Step {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/**
 * M1 step 1, in place of upstream core script 09.
 *
 * Upstream's `09_TransferPoolManagerOwner` hands the pool managers to `poolOwner` - for us the
 * timelock - and leaves the PoolManagerOwner contracts owning nothing. That is upstream's
 * older path, from before those contracts existed: script 09 still calls itself
 * `06_TransferPoolManagerOwner` in its own docstring, and script 06's step 3 says the multisig
 * should afterwards hand the pool manager to the owner contract by hand.
 *
 * We do that step directly instead, for one operational reason. `CLPoolManagerOwner` inherits
 * `PausableRole`, which lets the owner grant a pause-only role to a monitoring key. With the
 * timelock owning the pool manager directly there is no such role: an emergency pause would
 * need a 2-of-3 Safe signature plus the full timelock delay, which on mainnet is the
 * difference between pausing in seconds and pausing tomorrow. Routing ownership through the
 * owner contract also keeps `setProtocolFeeController` and `pause`/`unpause` behind one
 * reviewed surface, which is what the contract exists for.
 *
 * End state:  Safe -> TimelockController -> CL/BinPoolManagerOwner -> CL/BinPoolManager
 *
 * Runs AFTER the timelock has accepted the owner contracts, never before: until it does, the
 * owner contracts are owned by the CREATE3 proxy child that deployed them, which can never be
 * called again. Handing the pool managers over first would put them behind a dead owner.
 *
 * forge script script/03_TransferPoolManagers.s.sol:TransferPoolManagers -vv \
 *     --rpc-url $RPC_URL --broadcast
 */
contract TransferPoolManagers is BaseScript {
    function run() public {
        address timelock = readAddress("governance.timelock");
        address clPoolManager = readAddress("infinity.clPoolManager");
        address binPoolManager = readAddress("infinity.binPoolManager");
        address clPoolManagerOwner = readAddress("infinity.clPoolManagerOwner");
        address binPoolManagerOwner = readAddress("infinity.binPoolManagerOwner");

        // The safety interlock for the ordering above. `owner()` on the PoolManagerOwner
        // contracts must already be the timelock; if it is still the CREATE3 proxy child, this
        // run would be handing the pool managers to something nobody can operate.
        require(IOwnable1Step(clPoolManagerOwner).owner() == timelock, "CLPoolManagerOwner not accepted by timelock");
        require(IOwnable1Step(binPoolManagerOwner).owner() == timelock, "BinPoolManagerOwner not accepted by timelock");

        vm.startBroadcast(deployerKey());
        _transfer("CLPoolManager", clPoolManager, clPoolManagerOwner);
        _transfer("BinPoolManager", binPoolManager, binPoolManagerOwner);
        vm.stopBroadcast();
    }

    /// @dev infinity-core's own `base/Ownable.sol` is one-step, so this takes effect
    /// immediately - there is no acceptance to chase afterwards.
    function _transfer(string memory what, address poolManager, address newOwner) internal {
        if (IOwnable1Step(poolManager).owner() == newOwner) {
            console.log(string.concat("  ", what, " already owned by its owner contract"));
            return;
        }
        IOwnable1Step(poolManager).transferOwnership(newOwner);
        console.log(string.concat("  ", what, " ownership ->"), newOwner);
    }
}
