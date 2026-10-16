// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @notice Builds Pyth Pro (Lazer) updates in the EVM format, signed by a test key, so a test can
/// say exactly what the signer published.
library LazerBuilder {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint32 internal constant EVM_MAGIC = 0x2A22999A;
    uint32 internal constant PAYLOAD_MAGIC = 0x93C7D375;
    uint8 internal constant FIXED_RATE_200 = 3;

    /// @param feedTimestampUs zero leaves property 12 out
    /// @param bestBid and `bestAsk`: both zero leaves properties 1 and 2 out
    /// @param session negative leaves property 9 out
    struct Feed {
        uint32 id;
        int64 price;
        int16 exponent;
        uint64 confidence;
        uint64 feedTimestampUs;
        int64 bestBid;
        int64 bestAsk;
        int16 session;
    }

    /// @notice A plain feed as Pyth sends it today: price, exponent, confidence, feed timestamp.
    function plain(uint32 id, int64 price, int16 exponent, uint64 feedTimestampUs) internal pure returns (Feed memory) {
        return Feed(id, price, exponent, 1, feedTimestampUs, 0, 0, -1);
    }

    function payload(uint64 timestampUs, Feed[] memory feeds) internal pure returns (bytes memory p) {
        p = abi.encodePacked(PAYLOAD_MAGIC, timestampUs, FIXED_RATE_200, uint8(feeds.length));
        for (uint256 i; i < feeds.length; ++i) {
            Feed memory f = feeds[i];
            bool quote = f.bestBid != 0 || f.bestAsk != 0;
            uint8 n = 3 + (f.feedTimestampUs != 0 ? 1 : 0) + (quote ? 2 : 0) + (f.session >= 0 ? 1 : 0);
            p = abi.encodePacked(p, f.id, n, uint8(0), f.price, uint8(4), f.exponent, uint8(5), f.confidence);
            if (quote) p = abi.encodePacked(p, uint8(1), f.bestBid, uint8(2), f.bestAsk);
            if (f.session >= 0) p = abi.encodePacked(p, uint8(9), f.session);
            if (f.feedTimestampUs != 0) p = abi.encodePacked(p, uint8(12), uint8(1), f.feedTimestampUs);
        }
    }

    function sign(uint256 key, bytes memory payload_) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(key, keccak256(payload_));
        return abi.encodePacked(EVM_MAGIC, r, s, v - 27, uint16(payload_.length), payload_);
    }

    function one(uint256 key, uint64 timestampUs, Feed memory f) internal pure returns (bytes memory) {
        Feed[] memory feeds = new Feed[](1);
        feeds[0] = f;
        return sign(key, payload(timestampUs, feeds));
    }
}
