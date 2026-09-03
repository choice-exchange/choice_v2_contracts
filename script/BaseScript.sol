// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";

/// @notice Shared plumbing for Choice v2 deploy scripts.
///
/// Every address a script reads or writes goes through `deployments/injective_<network>.json`.
/// That file is the single source of truth for the frontend, the backend, the launchpad and
/// the sdk (plan §3), so a script that took an address from `.env` would let those four
/// consumers disagree with the chain without anything failing. The only thing the environment
/// supplies is which network file to open, plus the deployer key, which must never be written
/// to disk at all.
abstract contract BaseScript is Script {
    string internal bookPath;

    function setUp() public virtual {
        string memory network = vm.envOr("NETWORK", string("injective_testnet"));
        bookPath = string.concat(vm.projectRoot(), "/deployments/", network, ".json");
        console.log("[BaseScript] address book:", bookPath);
    }

    function book() internal view returns (string memory) {
        return vm.readFile(bookPath);
    }

    /// @dev Reverts on a null or zero entry. Scripts run in sequence and each one reads what
    /// the last one wrote, so a missing address must stop the run rather than silently deploy
    /// something wired to `address(0)`.
    function readAddress(string memory key) internal view returns (address a) {
        a = vm.parseJsonAddress(book(), string.concat(".", key));
        require(a != address(0), string.concat("address book: ", key, " is not set"));
    }

    /// @notice Like `readAddress`, but `address(0)` for a key that is absent or still null.
    /// @dev Deploy steps are re-run after a dropped receipt (Injective returns a null receipt
    /// for a mined tx), so every script has to be able to ask "is this already done?" without
    /// reverting on a book entry that has not been filled yet.
    function readAddressOrZero(string memory key) internal view returns (address) {
        string memory json = book();
        string memory path = string.concat(".", key);
        if (!vm.keyExistsJson(json, path)) return address(0);
        bytes memory raw = vm.parseJson(json, path);
        if (raw.length != 32) return address(0);
        return abi.decode(raw, (address));
    }

    function readUint(string memory key) internal view returns (uint256) {
        return vm.parseJsonUint(book(), string.concat(".", key));
    }

    function readAddressArray(string memory key) internal view returns (address[] memory) {
        return vm.parseJsonAddressArray(book(), string.concat(".", key));
    }

    /// @dev Writes straight back into the book so the next script in the sequence can read it.
    function writeAddress(string memory key, address value) internal {
        vm.writeJson(vm.toString(value), bookPath, string.concat(".", key));
        console.log(string.concat("  book.", key, " ="), value);
    }

    /// @notice Fail the run before broadcasting if the contract we expect is not there.
    function requireCode(string memory what, address a) internal view {
        require(a.code.length > 0, string.concat(what, " has no code at the address in the book"));
    }

    /// @notice The deployer key, read at call time from the environment and never persisted.
    function deployerKey() internal view returns (uint256) {
        return vm.envUint("PRIVATE_KEY");
    }
}
