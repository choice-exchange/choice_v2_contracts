// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice The two calls a Solidly (Velodrome v1-style) pair needs to be swapped through. Pumex's
/// "V2" pairs on Injective are this shape: `getAmountOut(uint256,address)` (`0xf140a35a`),
/// `swap(uint256,uint256,address,bytes)` (`0x022c0d9f`) and a `stable()` flag choosing between the
/// `x·y` and `x³y + y³x` curves. They emit the UniswapV2 `Swap` topic, not Velodrome v2's.
interface ISolidlyPair {
    /// @notice Output for `amountIn` of `tokenIn` against the pair's current reserves, fee
    /// included, on whichever curve the pair runs.
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);

    /// @notice Pays out `amount0Out` / `amount1Out` and enforces the pair's invariant against the
    /// input already transferred in.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}
