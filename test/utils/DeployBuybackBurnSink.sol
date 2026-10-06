// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

import {IBurnableERC20} from "../../src/interfaces/IBurnableERC20.sol";
import {IBuybackBurnSink} from "../../src/interfaces/IBuybackBurnSink.sol";

/// @notice Deploy `BuybackBurnSink` from its ARTIFACT, with the constructor `new` would take.
/// @dev Tests never import the sink's source. It compiles under its own optimizer profile, and
/// importing it would move the importing test onto that profile, along with every contract the
/// test touches and every gas figure it measures. See `IBuybackBurnSink`.
///
/// A plain CREATE, so a `vm.expectRevert` before it catches a constructor revert exactly as it
/// would catch one from `new`. On that path the returned sink is the zero address.
function deployBuybackBurnSink(
    IBurnableERC20 burnToken,
    Currency quote,
    IVault vault,
    ICLPositionManager positionManager,
    address treasury,
    address owner,
    uint16 minBurnBps,
    uint16 burnBps
) returns (IBuybackBurnSink sink) {
    Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes memory code = abi.encodePacked(
        vm.getCode("BuybackBurnSink.sol:BuybackBurnSink"),
        abi.encode(burnToken, quote, vault, positionManager, treasury, owner, minBurnBps, burnBps)
    );
    address deployed;
    assembly ("memory-safe") {
        deployed := create(0, add(code, 0x20), mload(code))
    }
    sink = IBuybackBurnSink(deployed);
}
