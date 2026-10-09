// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {IChoiceAdapter} from "../../src/interfaces/IChoiceAdapter.sol";

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

/// An honest adapter over a fixed-price venue with a CAPACITY - the shape of a bonding curve near
/// its graduation target: it fills at `rateE18` until `capacityIn` of input has been used, and hands
/// the rest of the input back. It keeps an inventory of output tokens, as a venue does, and so
/// measures everything by balance delta: an inventory or a donation is never paid to a caller.
/// `data` = `abi.encode(uint256 marketId)`.
contract MockCapacityAdapter is IChoiceAdapter {
    struct Market {
        uint256 rateE18; // tokenOut raw per tokenIn raw, x1e18
        uint256 capacityIn; // tokenIn raw still fillable
    }

    mapping(bytes32 => Market) public market;

    function setMarket(uint256 id, address tokenIn, address tokenOut, uint256 rateE18, uint256 capacityIn) external {
        market[_key(id, tokenIn, tokenOut)] = Market(rateE18, capacityIn);
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata data)
        public
        view
        returns (uint256 amountOut, uint256 amountInUsed)
    {
        Market memory m = market[_key(abi.decode(data, (uint256)), tokenIn, tokenOut)];
        amountInUsed = amountIn < m.capacityIn ? amountIn : m.capacityIn;
        amountOut = (amountInUsed * m.rateE18) / 1e18;
        if (amountOut == 0) amountInUsed = 0;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, address recipient, bytes calldata data)
        external
        returns (uint256 amountOut)
    {
        uint256 used;
        (amountOut, used) = quote(tokenIn, tokenOut, amountIn, data);
        require(amountOut != 0, "adapter: will not trade");
        market[_key(abi.decode(data, (uint256)), tokenIn, tokenOut)].capacityIn -= used;
        // Paid first: the input must already be here. The venue keeps what it used.
        require(IERC20(tokenIn).balanceOf(address(this)) >= amountIn, "adapter: not paid");
        IERC20(tokenOut).transfer(recipient, amountOut);
        if (amountIn > used) IERC20(tokenIn).transfer(msg.sender, amountIn - used);
    }

    function _key(uint256 id, address tokenIn, address tokenOut) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, tokenIn, tokenOut));
    }
}

/// An adapter that does whatever the test arms it to, before paying `payOut` of `tokenOut` from its
/// own inventory and returning `claimed`. Every hostile thing an adapter could try is one of these
/// knobs: keep the input (`payOut = 0`), pay dust, lie in its return value, call back into
/// anything (`target` / `callData`, reverting with the callee's error if `bubble`), pull from its
/// caller, or push native INJ at it.
contract MockHostileAdapter is IChoiceAdapter {
    address public target;
    bytes public callData;
    bool public bubble;
    uint256 public payOut;
    uint256 public claimed;
    bool public tryPull;
    bool public pullSucceeded;
    uint256 public nativeToCaller;

    function arm(address target_, bytes calldata callData_, bool bubble_) external {
        target = target_;
        callData = callData_;
        bubble = bubble_;
    }

    function setPay(uint256 payOut_, uint256 claimed_) external {
        payOut = payOut_;
        claimed = claimed_;
    }

    function setPull(bool on) external {
        tryPull = on;
    }

    function setNativeToCaller(uint256 amount) external {
        nativeToCaller = amount;
    }

    function quote(address, address, uint256 amountIn, bytes calldata) external view returns (uint256, uint256) {
        return (claimed, amountIn);
    }

    function swap(address tokenIn, address tokenOut, uint256, address recipient, bytes calldata)
        external
        returns (uint256)
    {
        if (target != address(0)) {
            (bool ok, bytes memory ret) = target.call(callData);
            if (!ok && bubble) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        if (tryPull) {
            // Everything the caller holds of either token, donations included.
            address[2] memory tokens = [tokenIn, tokenOut];
            for (uint256 i; i < 2; ++i) {
                uint256 bal = IERC20(tokens[i]).balanceOf(msg.sender);
                if (bal == 0) continue;
                try IERC20(tokens[i]).transferFrom(msg.sender, address(this), bal) {
                    pullSucceeded = true;
                } catch {}
            }
        }
        if (nativeToCaller != 0) {
            (bool ok, bytes memory ret) = msg.sender.call{value: nativeToCaller}("");
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        if (payOut != 0) IERC20(tokenOut).transfer(recipient, payOut);
        return claimed;
    }

    receive() external payable {}
}

/// An adapter that, inside its own step, dumps `dump` of `dumpToken` into a Solidly pair a LATER
/// step of the same route trades against, then pays one unit of its step's output. It cannot
/// touch the route's money; what it can do is move a price the route has not reached yet.
contract MockSandwichAdapter is IChoiceAdapter {
    MockSolidlyPair public immutable pair;
    address public immutable dumpToken;
    uint256 public immutable dump;

    constructor(MockSolidlyPair pair_, address dumpToken_, uint256 dump_) {
        pair = pair_;
        dumpToken = dumpToken_;
        dump = dump_;
    }

    function quote(address, address, uint256 amountIn, bytes calldata) external pure returns (uint256, uint256) {
        return (amountIn, amountIn);
    }

    function swap(address, address tokenOut, uint256, address recipient, bytes calldata) external returns (uint256) {
        uint256 out = pair.getAmountOut(dump, dumpToken);
        IERC20(dumpToken).transfer(address(pair), dump);
        bool zeroIn = pair.token0() == dumpToken;
        pair.swap(zeroIn ? 0 : out, zeroIn ? out : 0, address(this), "");
        IERC20(tokenOut).transfer(recipient, 1);
        return 1;
    }
}
