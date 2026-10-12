// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IPriceStore} from "../interfaces/IPriceStore.sol";

/// @title PythLazerLib
/// @notice Reads Pyth Pro (Lazer) updates in the EVM format, without calling Pyth's verifier.
///
/// **Envelope**: magic `0x2A22999A` (4 bytes), signature `r` (32), `s` (32), recovery id 0 or 1 (1),
/// payload length (2, big-endian), payload. The signature is over `keccak256(payload)` with no
/// prefix. Bytes after the payload are ignored, as the verifier ignores them.
///
/// **Payload**: magic `0x93C7D375` (4), timestamp in microseconds (8), channel (1), feed count (1),
/// then per feed: id (4), property count (1), and that many `(id, value)` properties, all big-endian.
/// Value widths follow the property id; ids 6, 7, 8 and 12 carry a one-byte "exists" flag and the
/// value only when it is set. Layout as in pyth-crosschain `lazer/contracts/evm` (PythLazerLib).
library PythLazerLib {
    uint32 internal constant EVM_MAGIC = 0x2A22999A;
    uint32 internal constant PAYLOAD_MAGIC = 0x93C7D375;
    uint256 internal constant ENVELOPE_HEADER = 71;
    uint256 internal constant PAYLOAD_HEADER = 14;

    uint8 internal constant HAS_QUOTE = 1;
    uint8 internal constant HAS_CONFIDENCE = 2;
    uint8 internal constant HAS_SESSION = 4;
    uint8 internal constant HAS_FEED_TIMESTAMP = 8;

    uint8 internal constant SESSION_CLOSED = 4;

    error MalformedUpdate();
    error UnknownProperty(uint8 property);

    /// @notice The update's signer, or zero for an invalid or high-s signature, and its payload.
    function recover(bytes calldata update) internal pure returns (address signer, bytes calldata payload) {
        if (update.length < ENVELOPE_HEADER || uint32(bytes4(update[0:4])) != EVM_MAGIC) revert MalformedUpdate();
        uint256 len = uint16(bytes2(update[69:71]));
        if (update.length < ENVELOPE_HEADER + len) revert MalformedUpdate();
        payload = update[ENVELOPE_HEADER:ENVELOPE_HEADER + len];
        uint8 v = uint8(update[68]);
        if (v > 1) revert MalformedUpdate();
        (address recovered, ECDSA.RecoverError err,) =
            ECDSA.tryRecover(keccak256(payload), v + 27, bytes32(update[4:36]), bytes32(update[36:68]));
        if (err == ECDSA.RecoverError.NoError) signer = recovered;
    }

    /// @return timestampUs the update's time
    /// @return channel the channel code (3 = FixedRate200)
    /// @return feeds how many feeds follow
    /// @return pos where the first feed starts
    function header(bytes calldata payload)
        internal
        pure
        returns (uint64 timestampUs, uint8 channel, uint8 feeds, uint256 pos)
    {
        if (payload.length < PAYLOAD_HEADER || uint32(bytes4(payload[0:4])) != PAYLOAD_MAGIC) {
            revert MalformedUpdate();
        }
        timestampUs = uint64(bytes8(payload[4:12]));
        channel = uint8(payload[12]);
        feeds = uint8(payload[13]);
        pos = PAYLOAD_HEADER;
    }

    /// @notice Read the feed starting at `pos`. A slice past the end reverts.
    /// @return feedId the feed's id
    /// @return p the feed's values, `timestampUs` set to the update's
    /// @return next where the next feed starts
    function readFeed(bytes calldata payload, uint256 pos, uint64 timestampUs)
        internal
        pure
        returns (uint32 feedId, IPriceStore.Price memory p, uint256 next)
    {
        feedId = uint32(bytes4(payload[pos:pos + 4]));
        uint256 n = uint8(payload[pos + 4]);
        pos += 5;
        p.timestampUs = timestampUs;
        for (uint256 k; k < n; ++k) {
            uint8 prop = uint8(payload[pos]);
            pos += 1;
            if (prop == 0) {
                p.price = _i64(payload, pos);
                pos += 8;
            } else if (prop == 1) {
                p.bestBid = _i64(payload, pos);
                pos += 8;
            } else if (prop == 2) {
                p.bestAsk = _i64(payload, pos);
                pos += 8;
            } else if (prop == 3) {
                pos += 2; // publisher count
            } else if (prop == 4) {
                p.exponent = int16(uint16(bytes2(payload[pos:pos + 2])));
                pos += 2;
            } else if (prop == 5) {
                p.confidence = uint64(bytes8(payload[pos:pos + 8]));
                p.flags |= HAS_CONFIDENCE;
                pos += 8;
            } else if (prop == 6 || prop == 7 || prop == 8) {
                // funding rate, funding timestamp, funding interval: flag, then the value if set
                pos += payload[pos] != 0 ? 9 : 1;
            } else if (prop == 9) {
                int16 session = int16(uint16(bytes2(payload[pos:pos + 2])));
                if (session < 0 || session > int16(uint16(SESSION_CLOSED))) revert MalformedUpdate();
                // forge-lint: disable-next-line(unsafe-typecast) - range checked above.
                p.marketSession = uint8(uint16(session));
                p.flags |= HAS_SESSION;
                pos += 2;
            } else if (prop == 10 || prop == 11) {
                pos += 8; // EMA price, EMA confidence
            } else if (prop == 12) {
                if (payload[pos] != 0) {
                    p.feedTimestampUs = uint64(bytes8(payload[pos + 1:pos + 9]));
                    p.flags |= HAS_FEED_TIMESTAMP;
                    pos += 9;
                } else {
                    pos += 1;
                }
            } else {
                revert UnknownProperty(prop);
            }
        }
        if (p.feedTimestampUs == 0 || p.feedTimestampUs > timestampUs) p.feedTimestampUs = timestampUs;
        if (p.bestBid > 0 && p.bestAsk > 0 && p.bestAsk >= p.bestBid) {
            p.flags |= HAS_QUOTE;
        } else {
            (p.bestBid, p.bestAsk) = (0, 0);
        }
        next = pos;
    }

    /// @notice The feed id at `pos` and where the next feed starts, without decoding any value.
    function skipFeed(bytes calldata payload, uint256 pos) internal pure returns (uint32 feedId, uint256 next) {
        feedId = uint32(bytes4(payload[pos:pos + 4]));
        uint256 n = uint8(payload[pos + 4]);
        pos += 5;
        for (uint256 k; k < n; ++k) {
            uint8 prop = uint8(payload[pos]);
            if (prop <= 2 || prop == 5 || prop == 10 || prop == 11) {
                pos += 9;
            } else if (prop == 3 || prop == 4 || prop == 9) {
                pos += 3;
            } else if (prop == 6 || prop == 7 || prop == 8 || prop == 12) {
                pos += payload[pos + 1] != 0 ? 10 : 2;
            } else {
                revert UnknownProperty(prop);
            }
        }
        next = pos;
    }

    function _i64(bytes calldata b, uint256 pos) private pure returns (int64) {
        return int64(uint64(bytes8(b[pos:pos + 8])));
    }
}
