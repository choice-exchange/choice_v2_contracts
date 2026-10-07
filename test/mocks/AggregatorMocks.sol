// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// A bank-backed (MTS) token as the swap precompile sees it: an ordinary ERC20 to every contract,
/// plus `mint` / `burn` that the precompile mock uses as its bank credit and debit (no allowance,
/// like the real one).
contract MockBankERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) public {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// WETH9-style wINJ: `deposit` wraps native 1:1, `withdraw` unwraps and pays the native back
/// through the caller's `receive`.
contract MockWINJ is MockBankERC20 {
    constructor() MockBankERC20("Wrapped INJ", "wINJ", 18) {}

    function deposit() external payable {
        mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "winj: native send failed");
    }
}

/// The v1.20.4 spot swap precompile at `0x…68`, faithful to what a devnet run of the official
/// binary MEASURED on 2026-09-24 - not to what its ABI implies:
///
/// * `address(0)` is native INJ; a market's side is implied by `tokenIn`.
/// * The fill is FLOORED to the quantity tick; the remainder is not taken.
/// * Past the book's depth the swap PARTIALLY FILLS and does not revert.
/// * Fee = `feeE18` of the notional, charged on the quote side both ways.
/// * No allowance: balances move like a bank debit, and native INJ is credited WITHOUT a call -
///   the recipient's `receive` never runs.
/// * Unlisted market, stale deadline and `minOut` all revert.
///
/// 🔴 It accepts an ERC20 quote token as `tokenIn`. The real v1.20.4 precompile refuses an
/// `erc20:` token there (EVM-native USDC); this mock models the chain AFTER that bug is fixed,
/// which is the chain the aggregator is built for.
///
/// One flat price per side stands in for a ladder - the contract under test never sees a level,
/// only what moved. Deploy it, then `vm.etch` its code to `0x…68` and configure markets THERE.
contract MockHelixSwap {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Market {
        address base; // address(0) = native INJ
        address quote; // address(0) = native INJ
        uint256 bidE18; // quote raw per base raw, x1e18
        uint256 askE18;
        uint256 bidDepth; // base raw
        uint256 askDepth; // base raw
        uint256 qtyTick; // base raw
        uint256 feeE18;
        uint256 minNotional; // quote raw; the chain's `min_notional`, $1 on the live books
        bool allowed;
    }

    mapping(bytes32 => Market) public markets;

    function setMarket(string calldata id, Market calldata m) external {
        markets[keccak256(bytes(id))] = m;
    }

    function quoteExactInputV1(address tokenIn, string calldata id, uint256 amountIn)
        external
        view
        returns (uint256 out)
    {
        (, out,) = _fill(markets[keccak256(bytes(id))], tokenIn, amountIn);
    }

    function swapExactInputV1(
        address tokenIn,
        string calldata id,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 out) {
        require(deadline >= block.timestamp, "swap: deadline exceeded");
        Market storage m = markets[keccak256(bytes(id))];
        require(m.allowed, "market is not allowlisted for swaps: invalid swap route");

        (uint256 spent, uint256 got, uint256 qty) = _fill(m, tokenIn, amountIn);
        require(got >= minOut, "swap: amount out below minimum");

        bool sell = tokenIn == m.base;
        if (sell) m.bidDepth -= qty;
        else m.askDepth -= qty;

        _debit(tokenIn, msg.sender, spent);
        _credit(sell ? m.quote : m.base, recipient, got);
        return got;
    }

    function _fill(Market memory m, address tokenIn, uint256 amountIn)
        internal
        pure
        returns (uint256 spent, uint256 out, uint256 qty)
    {
        require(tokenIn == m.base || tokenIn == m.quote, "swap: token not in market");
        // Measured on mainnet 2026-10-07: both size checks run on the REQUESTED amount, before
        // the book's depth caps it, and both revert - quote and swap alike.
        if (tokenIn == m.base) {
            qty = (amountIn / m.qtyTick) * m.qtyTick;
            require(qty != 0, "swap input too small for the market's quantity tick size");
            require((qty * m.bidE18) / 1e18 >= m.minNotional, "swap notional is below market min notional");
            if (qty > m.bidDepth) qty = m.bidDepth;
            uint256 gross = (qty * m.bidE18) / 1e18;
            out = gross - (gross * m.feeE18) / 1e18;
            spent = qty;
        } else {
            uint256 unitCost = (m.askE18 * (1e18 + m.feeE18)) / 1e18;
            qty = (((amountIn * 1e18) / unitCost) / m.qtyTick) * m.qtyTick;
            require(qty != 0, "swap input too small for the market's quantity tick size");
            require((qty * m.askE18) / 1e18 >= m.minNotional, "swap notional is below market min notional");
            if (qty > m.askDepth) qty = m.askDepth;
            uint256 gross = (qty * m.askE18) / 1e18;
            spent = gross + (gross * m.feeE18) / 1e18;
            out = qty;
        }
    }

    function _debit(address token, address from, uint256 amount) internal {
        if (token == address(0)) VM.deal(from, from.balance - amount);
        else MockBankERC20(token).burn(from, amount);
    }

    function _credit(address token, address to, uint256 amount) internal {
        if (token == address(0)) VM.deal(to, to.balance + amount);
        else MockBankERC20(token).mint(to, amount);
    }
}

/// A volatile Solidly pair that ENFORCES its invariant, unlike a pair that pays whatever it is
/// asked: `swap` measures the input it was actually sent (balance over reserve) and refuses an
/// output above what that input buys. So a router that asked the wrong side, sent the wrong token,
/// or forgot to send at all fails here exactly as it would against the real pair.
contract MockSolidlyPair {
    address public immutable token0;
    address public immutable token1;
    uint16 public immutable feeBps;
    uint256 public reserve0;
    uint256 public reserve1;

    constructor(address t0, address t1, uint16 fee) {
        token0 = t0;
        token1 = t1;
        feeBps = fee;
    }

    function sync() public {
        reserve0 = IERC20(token0).balanceOf(address(this));
        reserve1 = IERC20(token1).balanceOf(address(this));
    }

    function getAmountOut(uint256 amountIn, address tokenIn) public view returns (uint256) {
        uint256 amountInAfterFee = (amountIn * (10_000 - feeBps)) / 10_000;
        (uint256 rIn, uint256 rOut) = tokenIn == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
        return (amountInAfterFee * rOut) / (rIn + amountInAfterFee);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        require(amount0Out > 0 || amount1Out > 0, "pair: nothing out");
        require(amount0Out == 0 || amount1Out == 0, "pair: both out");
        uint256 in0 = IERC20(token0).balanceOf(address(this)) - reserve0;
        uint256 in1 = IERC20(token1).balanceOf(address(this)) - reserve1;
        if (amount1Out > 0) {
            require(amount1Out <= getAmountOut(in0, token0), "pair: K");
            IERC20(token1).transfer(to, amount1Out);
        } else {
            require(amount0Out <= getAmountOut(in1, token1), "pair: K");
            IERC20(token0).transfer(to, amount0Out);
        }
        sync();
    }
}
