// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IOraclePrecompile} from "../interfaces/IOraclePrecompile.sol";
import {PriceStore} from "./PriceStore.sol";

/// @title OraclePriceStore
/// @notice A `PriceStore` that also reads the Pyth Pro prices Injective's own oracle module already holds,
/// so stock vaults can run without a subscription of their own.
///
/// **Two sources, the newer wins.** Signed updates are verified and stored exactly as in `PriceStore`
/// (anyone may push one, or hand one to a fill as `hookData`): the payloads relayers publish to Injective
/// are Pyth-signed, so a keeper can take the newest out of a relay transaction. `latest` returns the newer
/// of that and the module's price for the feed, read from `0x67` (oracle type PythPro, the feed id as its
/// key, quoted in USD).
///
/// **How old the module's price is.** `0x67` dates a price by the block it landed in, in whole seconds,
/// not by the feed's own time. Relayers land an update about 0.8 s after Pyth publishes it (2 s at p99), so
/// the store dates the module's price (`feedTimestampUs`) `relayLagMs` earlier, rounded down to the second,
/// and a reader judging staleness sees it at least that old. Its `timestampUs` is when it landed: a signed
/// update from before then may be older than it, so a vault takes one handed to a fill only if its feed
/// moved after that. A feed whose market is shut stops landing (the module keeps only a newer feed time), so
/// its date stays at the close, as weekend mode needs.
contract OraclePriceStore is PriceStore {
    IOraclePrecompile internal constant ORACLE = IOraclePrecompile(0x0000000000000000000000000000000000000067);
    uint8 internal constant PYTH_PRO = 14;
    /// @dev The module's 1e18 price as a mantissa at this exponent.
    int16 internal constant EXPONENT = -8;
    uint32 public constant MAX_RELAY_LAG_MS = 5000;

    uint32 public relayLagMs;

    error BadRelayLag(uint32 lagMs);

    event RelayLagSet(uint32 lagMs);

    constructor(address owner_, address signer, uint64 expiresAt, uint32 relayLagMs_)
        PriceStore(owner_, signer, expiresAt)
    {
        _setRelayLag(relayLagMs_);
    }

    /// @notice The newer of the stored signed update and the oracle module's price.
    function latest(uint32 feedId) external view override returns (Price memory p) {
        p = _prices[feedId];
        Price memory m = moduleLatest(feedId);
        if (m.feedTimestampUs > p.feedTimestampUs) p = m;
    }

    /// @notice The oracle module's price for `feedId`: its feed time `relayLagMs` before the second it
    /// landed, its batch time that second; all zero when the module has none.
    function moduleLatest(uint32 feedId) public view returns (Price memory p) {
        try ORACLE.oraclePricePairState(PYTH_PRO, Strings.toString(feedId), "USD") returns (
            IOraclePrecompile.PricePairState memory s
        ) {
            uint256 mantissa = s.pairPrice / 1e10;
            uint256 lagUs = uint256(relayLagMs) * 1000;
            uint256 landedUs = uint256(s.baseTimestamp) * 1e6;
            if (mantissa == 0 || mantissa > uint64(type(int64).max) || landedUs <= lagUs) return p;
            p.timestampUs = uint64(landedUs);
            p.feedTimestampUs = uint64(landedUs - lagUs);
            // forge-lint: disable-next-line(unsafe-typecast) - bounded by int64's max above.
            p.price = int64(uint64(mantissa));
            p.exponent = EXPONENT;
        } catch {}
    }

    /// @notice How long before its block a module price is taken to have been published.
    function setRelayLag(uint32 lagMs) external onlyOwner {
        _setRelayLag(lagMs);
    }

    function _setRelayLag(uint32 lagMs) internal {
        if (lagMs > MAX_RELAY_LAG_MS) revert BadRelayLag(lagMs);
        relayLagMs = lagMs;
        emit RelayLagSet(lagMs);
    }
}
