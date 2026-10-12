// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @notice The one `0x67` oracle-precompile method a price reader needs.
/// @dev Signature taken from injective-core's abigen bindings
/// (`injective-chain/modules/evm/precompiles/bindings/cosmos/precompile/oracle`); selector
/// `0x20374400`. Only the method used here is declared, so a partial interface cannot drift
/// into a wrong selector.
///
/// **How to read it** (the backend's `docs/ORACLE.md` reaches the same rules):
/// - every value is 1e18-scaled;
/// - read `pairPrice`; with `quote == "USD"` it is the base price alone;
/// - a feed that does not exist REVERTS (`ErrOraclePriceNotFound`), it never returns zero;
/// - age is `block.timestamp - baseTimestamp`; a market that is closed keeps its last timestamp,
///   so a stale feed is told apart from a live one by age, never by price;
/// - a PythPro `base` is the decimal Lazer feed id as a string. Feed ids are configuration,
///   chosen by a person, never derived.
interface IOracleModule {
    struct PricePairState {
        uint256 pairPrice;
        uint256 basePrice;
        uint256 quotePrice;
        uint256 baseCumulativePrice;
        uint256 quoteCumulativePrice;
        uint64 baseTimestamp;
        uint64 quoteTimestamp;
    }

    /// @param oracleType the oracle module's enum: 14 is PythPro, 13 Chainlink Data Streams, 9 Pyth
    function oraclePricePairState(uint8 oracleType, string calldata base, string calldata quote)
        external
        view
        returns (PricePairState memory state);
}
