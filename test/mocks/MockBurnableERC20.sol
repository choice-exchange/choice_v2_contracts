// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice `MockERC20` plus the one method `IBurnableERC20` needs.
///
/// Deliberately shaped like Injective's `MintBurnBankERC20`: `burn(uint256)` destroys the
/// CALLER's own balance, reduces `totalSupply`, and is **not** owner-gated - which is the
/// behaviour verified against the real creation bytecode on 2026-09-05. A mock that let an
/// arbitrary address burn someone else's balance, or that left `totalSupply` untouched, would
/// let a test pass that the real token would fail.
contract MockBurnableERC20 is MockERC20 {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) {}

    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }
}
