// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IStockRatios} from "../interfaces/IStockRatios.sol";

/// @title StockRatios
/// @notice How many stock tokens make one share of the underlying, per token. A tokenized stock whose
/// issuer keeps balances fixed through a split changes this ratio instead: after a 4:1 split one token
/// is four shares, so the ratio goes from one to a quarter and the feed's per-share price falls by four.
///
/// **It can only halt.** A stock vault reads the ratio with every price it acts on. One that differs from
/// the ratio the vault last accepted halts the vault until its owner accepts the new one. So the updater
/// (the issuer's key, or a keeper mirroring the issuer) can stop a vault but never move one of its prices.
/// One per deployment.
contract StockRatios is IStockRatios, Ownable2Step {
    uint256 public constant ONE = 1e12;
    /// @dev The range a vault accepts: a millionth of a token per share up to ten thousand.
    uint256 public constant MIN_RATIO = 1e6;
    uint256 public constant MAX_RATIO = 1e16;

    address public updater;
    mapping(address token => uint256) internal _ratio;

    error NotUpdater();
    error BadRatio(uint256 ratio);

    event UpdaterSet(address updater);
    event RatioSet(address indexed token, uint256 ratio, uint256 previous);

    constructor(address owner_, address updater_) Ownable(owner_) {
        updater = updater_;
        emit UpdaterSet(updater_);
    }

    /// @inheritdoc IStockRatios
    function tokenPerShare(address token) external view returns (uint256) {
        uint256 r = _ratio[token];
        return r == 0 ? ONE : r;
    }

    /// @notice Announce `token`'s ratio. The updater or the owner.
    function setRatio(address token, uint256 ratio) external {
        if (msg.sender != updater && msg.sender != owner()) revert NotUpdater();
        if (ratio < MIN_RATIO || ratio > MAX_RATIO) revert BadRatio(ratio);
        uint256 previous = _ratio[token];
        _ratio[token] = ratio;
        emit RatioSet(token, ratio, previous == 0 ? ONE : previous);
    }

    function setUpdater(address updater_) external onlyOwner {
        updater = updater_;
        emit UpdaterSet(updater_);
    }
}
