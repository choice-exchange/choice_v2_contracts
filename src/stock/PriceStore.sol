// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IPriceStore} from "../interfaces/IPriceStore.sol";
import {PythLazerLib} from "./PythLazerLib.sol";

/// @title PriceStore
/// @notice Signed Pyth Pro prices for every stock vault, verified here against a pinned signer.
///
/// **Why not Pyth's verifier contract.** It is an upgradeable proxy whose owner could make it pass
/// anything, and Injective's own oracle (`0x67`) stores only what that verifier passed, minus the
/// session, quote and confidence fields. This contract recovers the signer itself (about 5k gas)
/// and accepts only signers the owner has pinned, each with an expiry. Rotating one is a
/// timelocked owner call, the same trust as the vaults' own settings.
///
/// **Freshness is the reader's job.** `update` keeps, per feed, the newest update by its own
/// timestamp, so nobody can roll a feed back; a reader decides how old is too old, and must
/// judge a feed by `feedTimestampUs`, not by the batch's time.
///
/// Anyone may call `update`: every value it can store carries the signer's signature.
contract PriceStore is IPriceStore, Ownable2Step {
    mapping(address signer => uint64 expiresAt) public signerExpiry;
    mapping(uint32 feedId => Price) internal _prices;

    error UntrustedSigner(address signer);
    error FeedNotFound(uint32 feedId);

    event SignerSet(address indexed signer, uint64 expiresAt);
    event Updated(uint64 timestampUs, uint256 stored);

    constructor(address owner_, address signer, uint64 expiresAt) Ownable(owner_) {
        if (signer == address(0)) revert UntrustedSigner(signer);
        signerExpiry[signer] = expiresAt;
        emit SignerSet(signer, expiresAt);
    }

    /// @inheritdoc IPriceStore
    function latest(uint32 feedId) external view virtual returns (Price memory) {
        return _prices[feedId];
    }

    /// @inheritdoc IPriceStore
    function verify(bytes calldata update_, uint32 feedId) external view returns (Price memory p) {
        bytes calldata payload = _trusted(update_);
        (uint64 ts,, uint8 feeds, uint256 pos) = PythLazerLib.header(payload);
        for (uint256 k; k < feeds; ++k) {
            (uint32 id, uint256 next) = PythLazerLib.skipFeed(payload, pos);
            if (id == feedId) {
                (, p,) = PythLazerLib.readFeed(payload, pos, ts);
                return p;
            }
            pos = next;
        }
        revert FeedNotFound(feedId);
    }

    /// @inheritdoc IPriceStore
    function update(bytes calldata update_) external returns (uint256 stored) {
        bytes calldata payload = _trusted(update_);
        (uint64 ts,, uint8 feeds, uint256 pos) = PythLazerLib.header(payload);
        for (uint256 k; k < feeds; ++k) {
            uint32 id;
            Price memory p;
            (id, p, pos) = PythLazerLib.readFeed(payload, pos, ts);
            if (p.price > 0 && ts > _prices[id].timestampUs) {
                _prices[id] = p;
                ++stored;
            }
        }
        emit Updated(ts, stored);
    }

    /// @notice Trust `signer` until `expiresAt` (zero removes it).
    function setSigner(address signer, uint64 expiresAt) external onlyOwner {
        if (signer == address(0)) revert UntrustedSigner(signer);
        signerExpiry[signer] = expiresAt;
        emit SignerSet(signer, expiresAt);
    }

    function _trusted(bytes calldata update_) internal view returns (bytes calldata payload) {
        address signer;
        (signer, payload) = PythLazerLib.recover(update_);
        if (signerExpiry[signer] <= block.timestamp) revert UntrustedSigner(signer);
    }
}
