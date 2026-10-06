// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice Injective's spot SWAP precompile at `0x…0068`, added by the v1.20.4 upgrade: an atomic,
/// exact-input market swap against ONE Helix spot book, settled against the caller's BANK balance
/// inside the same transaction.
///
/// The ABI is the `swapABI` embedded in the official v1.20.4 binary (package
/// `modules/evm/precompiles/swap`). Behaviour measured end to end on a v1.20.4 devnet on
/// 2026-09-24, and on mainnet against the live allowlist on 2026-10-07:
///
/// * `tokenIn` is a bank token pair's ERC20, or `address(0)` for NATIVE INJ. wINJ is REJECTED
///   ("not registered as a bank token pair"). The side is implied by `tokenIn`: base sells, quote
///   buys. There is no orientation argument.
/// * No `approve`: the precompile debits the caller's bank balance directly. Native INJ out is
///   credited to the recipient's native balance.
/// * 🔴 "Exact input" is a MAXIMUM. The fill is floored to the market's quantity tick and the
///   remainder stays with the caller.
/// * 🔴 An order larger than the book PARTIALLY FILLS and does NOT revert. `minOut` is the only
///   thing in the call that stops it.
/// * The market must be in exchange `swap_params.allowed_markets`, else it reverts "not allowlisted
///   for swaps". Mainnet 2026-10-07: INJ/USDC, USDC/USDT, USDC/USDCnb.
/// * 🔴 An `erc20:` token (EVM-native USDC `0xa00C…`) cannot be `tokenIn` on v1.20.4: the
///   precompile's denom resolver reads only the ERC20-module pair index, which never holds an
///   `erc20:` pair. Reverts "not registered as a bank token pair". An Injective bug, expected to be
///   fixed in a chain upgrade; nothing here special-cases it.
/// * Gas: a flat ~201.6k EVM gas per call, independent of the levels crossed.
/// * `quoteExactInputV1` equals the executed output exactly at the same state.
interface IHelixSwap {
    function quoteExactInputV1(address tokenIn, string calldata marketId, uint256 amountIn)
        external
        view
        returns (uint256 amountOut);

    function quoteExactOutputV1(address tokenOut, string calldata marketId, uint256 amountOut)
        external
        view
        returns (uint256 amountIn);

    function swapExactInputV1(
        address tokenIn,
        string calldata marketId,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut);
}
