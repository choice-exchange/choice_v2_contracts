// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice A venue behind one generic call: whatever turns an exact input of one ERC20 into some
/// output of another. `ChoiceAggregator` reaches it through its `Adapter` step, so a new kind of
/// liquidity becomes routable by deploying an adapter, with no new aggregator.
///
/// **How it is called: paid first, then asked.** The caller TRANSFERS `amountIn` of `tokenIn` to
/// the adapter and calls `swap` in the same transaction. Nothing is approved to the adapter and
/// nothing is pulled from the caller, so the most an adapter can ever take is what it was sent.
///
/// **What an adapter owes the caller:**
/// - spend at most `amountIn`, and send every unit of it that it did not spend back to
///   `msg.sender` before returning (a venue that fills partially, or caps a fill, leaves some);
/// - send its output to `recipient`;
/// - measure both by balance delta, never by "everything I hold". Between transactions an adapter
///   should hold nothing, and whatever it does hold - a donation, a stray send - must not be paid
///   out to whoever calls next;
/// - send no native INJ: both tokens are ERC20s, and a caller may refuse native it did not ask for.
///
/// **What a caller must assume.** An adapter is code someone else deployed. Measure what it
/// delivered as a balance delta rather than trusting `swap`'s return value, guard the end-to-end
/// result, and never hand it anything but the one input.
interface IChoiceAdapter {
    /// @notice Trades `amountIn` of `tokenIn`, already transferred in, for `tokenOut`.
    /// @param data venue-specific: which market, in the adapter's own encoding
    /// @return amountOut what was sent to `recipient`
    function swap(address tokenIn, address tokenOut, uint256 amountIn, address recipient, bytes calldata data)
        external
        returns (uint256 amountOut);

    /// @notice What `swap` would do with the same arguments right now, for a planner.
    /// @return amountOut what `recipient` would receive; zero when the adapter will not trade
    /// @return amountInUsed how much of `amountIn` the venue would spend; the rest would come back
    function quote(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata data)
        external
        view
        returns (uint256 amountOut, uint256 amountInUsed);
}

/// @notice An adapter that can list its own markets, so a planner needs nothing but the adapter's
/// address to find everything behind it. Optional: an adapter over one fixed market need not.
interface IChoiceAdapterMarkets {
    /// @param data what `swap` and `quote` take to address this market
    /// @param reserve0 a PRICE signal, `reserve1 / reserve0` being the market's spot price. Not a
    /// depth to run constant-product maths on: ask `quote`. Both are zero when the market will not
    /// trade, which is how a planner drops it.
    struct Market {
        bytes data;
        address token0;
        address token1;
        uint256 reserve0;
        uint256 reserve1;
    }

    /// @notice How many market slots `markets` pages over. A slot may hold a market that is not
    /// trading (zero reserves), so the count is a paging bound, not a count of live markets.
    function marketCount() external view returns (uint256);

    /// @notice Slots `[start, start + count)`, clamped to `marketCount()`.
    function markets(uint256 start, uint256 count) external view returns (Market[] memory);
}
