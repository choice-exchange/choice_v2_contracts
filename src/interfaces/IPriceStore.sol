// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @notice A store of signed Pyth Pro (Lazer) prices, verified in-contract against a pinned signer.
interface IPriceStore {
    /// @notice One feed of one signed update, as the signer published it.
    /// @param timestampUs the update's own time, microseconds since 1970, on its channel's grid
    /// @param feedTimestampUs when this feed's price last changed upstream (Lazer property 12),
    /// never later than `timestampUs`; equal to it when the update does not carry the property.
    /// 🔴 Staleness is a per-feed question: a feed whose market is shut still rides every fresh
    /// batch, carrying its last close here.
    /// @param price the price mantissa: the value is `price * 10**exponent`; zero means missing
    /// @param bestBid and `bestAsk`: the market's quote, same scale; zero unless `flags` has `HAS_QUOTE`
    /// @param confidence Pyth's confidence band, same scale; meaningful only with `HAS_CONFIDENCE`
    /// @param marketSession Pyth's session code (0 regular, 1 pre-market, 2 post-market,
    /// 3 overnight, 4 closed); meaningful only with `HAS_SESSION`
    struct Price {
        uint64 timestampUs;
        uint64 feedTimestampUs;
        int64 price;
        int64 bestBid;
        int64 bestAsk;
        uint64 confidence;
        int16 exponent;
        uint8 marketSession;
        uint8 flags;
    }

    /// @notice The newest stored price of `feedId`; all zero if none was ever stored.
    function latest(uint32 feedId) external view returns (Price memory);

    /// @notice Verify a signed update and return its `feedId` entry, without storing anything.
    /// Reverts on an untrusted signer, a malformed update, or a feed the update does not carry.
    function verify(bytes calldata update, uint32 feedId) external view returns (Price memory);

    /// @notice Verify a signed update and store every feed in it that is newer than what is stored.
    /// @return stored how many feeds were newer and stored
    function update(bytes calldata update) external returns (uint256 stored);
}
