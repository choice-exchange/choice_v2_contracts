// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/// @notice Where a stock token's tokens-per-share ratio is announced (`StockRatios`).
interface IStockRatios {
    /// @notice How many tokens make one share, 1e12 = one; one for a token never set.
    function tokenPerShare(address token) external view returns (uint256);
}
