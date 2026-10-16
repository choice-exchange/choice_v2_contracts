// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/// @notice Injective's oracle module precompile (`0x67`), the one read a price store needs.
interface IOraclePrecompile {
    /// @param pairPrice base over quote, 1e18 fixed point
    /// @param baseTimestamp the block time, in seconds, at which the base price was last stored: not
    /// the feed's own time, which the module keeps but does not return
    struct PricePairState {
        uint256 pairPrice;
        uint256 basePrice;
        uint256 quotePrice;
        uint256 baseCumulativePrice;
        uint256 quoteCumulativePrice;
        uint64 baseTimestamp;
        uint64 quoteTimestamp;
    }

    /// @notice Reverts when the module has no price for the pair.
    function oraclePricePairState(uint8 oracleType, string calldata base, string calldata quote)
        external
        view
        returns (PricePairState memory);
}
