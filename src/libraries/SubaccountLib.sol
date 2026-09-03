// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @notice Derive an Injective exchange subaccount id from an EVM address.
///
/// A subaccount id is a 32-byte value that the precompile takes as a `0x`-prefixed,
/// 66-character LOWERCASE hex string: the 20-byte owner followed by a 12-byte nonce. The
/// default subaccount (nonce 0) is the address followed by 24 zeros.
///
/// @dev Ported from `choice_exchange_evm/src/libraries/SubaccountLib.sol`, where the encoding
/// was verified against real on-chain calldata.
library SubaccountLib {
    bytes16 private constant HEX = "0123456789abcdef";

    /// @notice Default (nonce-0) subaccount id string for `owner`.
    function defaultSubaccount(address owner) internal pure returns (string memory) {
        return subaccount(owner, 0);
    }

    /// @notice Subaccount id string for `owner` at `nonce`.
    function subaccount(address owner, uint96 nonce) internal pure returns (string memory) {
        bytes memory s = new bytes(66); // "0x" + 64 hex chars
        s[0] = "0";
        s[1] = "x";

        uint160 a = uint160(owner);
        for (uint256 i = 0; i < 20; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 b = uint8(a >> (8 * (19 - i)));
            s[2 + i * 2] = HEX[b >> 4];
            s[3 + i * 2] = HEX[b & 0x0f];
        }
        for (uint256 i = 0; i < 12; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 b = uint8(nonce >> (8 * (11 - i)));
            s[42 + i * 2] = HEX[b >> 4];
            s[43 + i * 2] = HEX[b & 0x0f];
        }
        return string(s);
    }
}
