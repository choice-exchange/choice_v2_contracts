// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IExchangeDerivatives} from "../../src/interfaces/IExchangeDerivatives.sol";

/// @notice Stands in for the `0x65` exchange precompile, `vm.etch`ed to its address, with the
/// semantics a stock vault depends on: an order holds margin when placed and fills (or is dropped)
/// at `endBlock`, against the price the test names; positions are per subaccount; funding accrues
/// off the books (`accrueFunding`) and reaches the margin only when `decreasePositionMargin` runs,
/// as on chain. Margin moves by minting and burning the cash mock, which is how the real precompile
/// debits a bank balance without an approval.
///
/// Post-only limit orders rest at once, as on chain: checked against the book's best bid and ask
/// (`setBook`) and reverted if they would cross, visible to `derivativeOrdersByHashes` in the same
/// transaction, filled as maker by `fillResting` and cancelled by matching with `matchCancel`.
contract MockStockExchange {
    struct Order {
        address sender;
        string subaccountID;
        string marketID;
        bool isBuy;
        uint256 worstPrice;
        uint256 quantity;
        uint256 margin;
    }

    struct Position {
        bool isLong;
        uint256 quantity;
        uint256 entryPrice;
        uint256 margin;
        int256 unsettledFunding;
    }

    MockERC20 public cash;
    uint256 public cashScale; // 10 ** (18 - cash decimals)
    Order[] internal _pending;
    mapping(bytes32 subaccount => mapping(bytes32 market => Position)) internal _positions;
    mapping(bytes32 subaccount => string[]) internal _markets;
    uint256 public ordersPlaced;
    uint256 public decreases;
    bool public failDecrease;

    struct Resting {
        address sender;
        string subaccountID;
        string marketID;
        bool isBuy;
        uint256 price;
        uint256 quantity;
        uint256 margin;
        uint256 fillable;
    }

    mapping(bytes32 hash => Resting) internal _resting;
    uint256 public bestBid;
    uint256 public bestAsk;
    uint256 public limitOrdersPlaced;
    uint256 public cancels;

    function setBook(uint256 bid, uint256 ask) external {
        (bestBid, bestAsk) = (bid, ask);
    }

    function createDerivativeLimitOrder(address sender, IExchangeDerivatives.DerivativeOrder calldata o)
        external
        returns (IExchangeDerivatives.CreateDerivativeLimitOrderResponse memory r)
    {
        require(msg.sender == sender, "authz");
        bool isBuy = keccak256(bytes(o.orderType)) == keccak256("buyPostOnly");
        require(isBuy || keccak256(bytes(o.orderType)) == keccak256("sellPostOnly"), "order type");
        require(isBuy ? (bestAsk == 0 || o.price < bestAsk) : o.price > bestBid, "exceeds top of book");
        if (o.margin != 0) cash.burn(sender, _toCash(o.margin, true));
        r.orderHash = Strings.toHexString(uint256(keccak256(abi.encode(address(this), ++limitOrdersPlaced))), 32);
        _resting[keccak256(bytes(r.orderHash))] =
            Resting(sender, o.subaccountID, o.marketID, isBuy, o.price, o.quantity, o.margin, o.quantity);
    }

    function cancelDerivativeOrder(
        address sender,
        string calldata,
        string calldata,
        string calldata orderHash,
        int32,
        string calldata
    ) external returns (bool) {
        require(msg.sender == sender, "authz");
        Resting storage o = _resting[keccak256(bytes(orderHash))];
        require(o.fillable != 0, "order doesnt exist");
        uint256 refund = o.margin * o.fillable / o.quantity;
        if (refund != 0) cash.mint(o.sender, _toCash(refund, false));
        delete _resting[keccak256(bytes(orderHash))];
        cancels++;
        return true;
    }

    function derivativeOrdersByHashes(IExchangeDerivatives.DerivativeOrdersRequest calldata q)
        external
        view
        returns (IExchangeDerivatives.TrimmedDerivativeLimitOrder[] memory out)
    {
        uint256 n;
        for (uint256 k; k < q.orderHashes.length; ++k) {
            if (_resting[keccak256(bytes(q.orderHashes[k]))].fillable != 0) n++;
        }
        out = new IExchangeDerivatives.TrimmedDerivativeLimitOrder[](n);
        uint256 j;
        for (uint256 k; k < q.orderHashes.length; ++k) {
            Resting storage o = _resting[keccak256(bytes(q.orderHashes[k]))];
            if (o.fillable == 0) continue;
            out[j++] = IExchangeDerivatives.TrimmedDerivativeLimitOrder({
                price: o.price,
                quantity: o.quantity,
                margin: o.margin,
                fillable: o.fillable,
                isBuy: o.isBuy,
                orderHash: q.orderHashes[k],
                cid: ""
            });
        }
    }

    /// @notice Fill `quantity` of a resting order at its own price, as the EndBlocker would match
    /// a taker against it: the filled part's margin moves into the position.
    function fillResting(string calldata orderHash, uint256 quantity) external {
        Resting storage o = _resting[keccak256(bytes(orderHash))];
        require(quantity <= o.fillable, "overfill");
        uint256 marginShare = o.margin * quantity / o.quantity;
        _apply(Order(o.sender, o.subaccountID, o.marketID, o.isBuy, o.price, quantity, marginShare), o.price);
        o.fillable -= quantity;
    }

    /// @notice Drop a resting order unfilled, as matching does when it fails a margin check; the
    /// rest of its margin comes back.
    function matchCancel(string calldata orderHash) external {
        Resting storage o = _resting[keccak256(bytes(orderHash))];
        uint256 refund = o.margin * o.fillable / o.quantity;
        if (refund != 0) cash.mint(o.sender, _toCash(refund, false));
        delete _resting[keccak256(bytes(orderHash))];
    }

    function setCash(MockERC20 cash_) external {
        cash = cash_;
        cashScale = 10 ** (18 - cash_.decimals());
    }

    function setFailDecrease(bool fail) external {
        failDecrease = fail;
    }

    function pendingCount() external view returns (uint256) {
        return _pending.length;
    }

    function pending(uint256 k) external view returns (Order memory) {
        return _pending[k];
    }

    function createDerivativeMarketOrder(address sender, IExchangeDerivatives.DerivativeOrder calldata o)
        external
        returns (IExchangeDerivatives.CreateDerivativeMarketOrderResponse memory r)
    {
        require(msg.sender == sender, "authz");
        bool isBuy = keccak256(bytes(o.orderType)) == keccak256("buy");
        require(isBuy || keccak256(bytes(o.orderType)) == keccak256("sell"), "order type");
        if (o.margin != 0) cash.burn(sender, _toCash(o.margin, true));
        _pending.push(Order(sender, o.subaccountID, o.marketID, isBuy, o.price, o.quantity, o.margin));
        ordersPlaced++;
        r.orderHash = "0xmock";
    }

    /// @notice Fill every pending order at `fillPrice` if its worst price allows, else drop it and
    /// release its margin.
    function endBlock(uint256 fillPrice) external {
        for (uint256 k; k < _pending.length; ++k) {
            Order memory o = _pending[k];
            bool fills = o.isBuy ? fillPrice <= o.worstPrice : fillPrice >= o.worstPrice;
            if (!fills) {
                if (o.margin != 0) cash.mint(o.sender, _toCash(o.margin, false));
                continue;
            }
            _apply(o, fillPrice);
        }
        delete _pending;
    }

    function _apply(Order memory o, uint256 fillPrice) internal {
        bytes32 sub = keccak256(bytes(o.subaccountID));
        bytes32 mkt = keccak256(bytes(o.marketID));
        Position storage p = _positions[sub][mkt];
        if (p.quantity == 0 && p.margin == 0) _markets[sub].push(o.marketID);
        bool opening = p.quantity == 0 || p.isLong == o.isBuy;
        if (opening) {
            p.entryPrice = (p.entryPrice * p.quantity + fillPrice * o.quantity) / (p.quantity + o.quantity);
            p.quantity += o.quantity;
            p.isLong = o.isBuy;
            p.margin += o.margin;
            return;
        }
        require(o.quantity <= p.quantity, "flip");
        uint256 marginShare = p.margin * o.quantity / p.quantity;
        int256 move = p.isLong ? int256(fillPrice) - int256(p.entryPrice) : int256(p.entryPrice) - int256(fillPrice);
        int256 payout = int256(marginShare) + move * int256(o.quantity) / 1e18;
        p.quantity -= o.quantity;
        p.margin -= marginShare;
        if (payout > 0) cash.mint(o.sender, _toCash(uint256(payout), false));
    }

    function increasePositionMargin(
        address sender,
        string calldata,
        string calldata dst,
        string calldata market,
        uint256 amount
    ) external returns (bool) {
        require(msg.sender == sender, "authz");
        cash.burn(sender, _toCash(amount, true));
        _positions[keccak256(bytes(dst))][keccak256(bytes(market))].margin += amount;
        return true;
    }

    /// @notice As on chain: applies the position's unsettled funding first, then moves `amount`.
    function decreasePositionMargin(
        address sender,
        string calldata src,
        string calldata,
        string calldata market,
        uint256 amount
    ) external returns (bool) {
        require(msg.sender == sender, "authz");
        require(!failDecrease, "decrease failed");
        Position storage p = _positions[keccak256(bytes(src))][keccak256(bytes(market))];
        require(p.quantity != 0, "no position");
        int256 m = int256(p.margin) + p.unsettledFunding;
        require(m >= int256(amount), "margin");
        p.unsettledFunding = 0;
        p.margin = uint256(m) - amount;
        uint256 out = _toCash(amount, false);
        if (out != 0) cash.mint(sender, out);
        decreases++;
        return true;
    }

    function subaccountPositions(string calldata subaccountID)
        external
        view
        returns (IExchangeDerivatives.DerivativePosition[] memory out)
    {
        bytes32 sub = keccak256(bytes(subaccountID));
        string[] storage markets = _markets[sub];
        uint256 n;
        for (uint256 k; k < markets.length; ++k) {
            if (_positions[sub][keccak256(bytes(markets[k]))].quantity != 0) n++;
        }
        out = new IExchangeDerivatives.DerivativePosition[](n);
        uint256 j;
        for (uint256 k; k < markets.length; ++k) {
            Position storage p = _positions[sub][keccak256(bytes(markets[k]))];
            if (p.quantity == 0) continue;
            // Raw state, as on chain: margin without the unsettled funding.
            out[j++] = IExchangeDerivatives.DerivativePosition({
                subaccountID: subaccountID,
                marketID: markets[k],
                isLong: p.isLong,
                quantity: p.quantity,
                entryPrice: p.entryPrice,
                margin: p.margin,
                cumulativeFundingEntry: 0
            });
        }
    }

    /// @notice Funding owed to (positive) or by (negative) a position, not yet in its margin.
    function accrueFunding(string calldata subaccountID, string calldata market, int256 amount) external {
        _positions[keccak256(bytes(subaccountID))][keccak256(bytes(market))].unsettledFunding += amount;
    }

    function setMargin(string calldata subaccountID, string calldata market, uint256 margin) external {
        _positions[keccak256(bytes(subaccountID))][keccak256(bytes(market))].margin = margin;
    }

    /// @notice Cut a position, as a liquidation would.
    /// @notice As a governance forced settlement: close the position at `price`, margin plus PnL paid
    /// to `holder`'s bank balance.
    function forceSettle(string calldata subaccountID, string calldata market, uint256 price, address holder) external {
        Position storage p = _positions[keccak256(bytes(subaccountID))][keccak256(bytes(market))];
        int256 move = p.isLong ? int256(price) - int256(p.entryPrice) : int256(p.entryPrice) - int256(price);
        int256 payout = int256(p.margin) + p.unsettledFunding + move * int256(p.quantity) / 1e18;
        (p.quantity, p.margin, p.unsettledFunding) = (0, 0, 0);
        if (payout > 0) cash.mint(holder, _toCash(uint256(payout), false));
    }

    function setQuantity(string calldata subaccountID, string calldata market, uint256 quantity) external {
        _positions[keccak256(bytes(subaccountID))][keccak256(bytes(market))].quantity = quantity;
    }

    function _toCash(uint256 api, bool up) internal view returns (uint256) {
        return up ? (api + cashScale - 1) / cashScale : api / cashScale;
    }
}

/// @notice Injective's oracle precompile at `0x67`, for PythPro prices quoted in USD: a price and the
/// block time (seconds) it landed at, per feed key; a key never set reverts, as on chain.
contract MockOraclePrecompile {
    struct PricePairState {
        uint256 pairPrice;
        uint256 basePrice;
        uint256 quotePrice;
        uint256 baseCumulativePrice;
        uint256 quoteCumulativePrice;
        uint64 baseTimestamp;
        uint64 quoteTimestamp;
    }

    mapping(bytes32 key => PricePairState) internal _states;

    function set(string calldata base, uint256 price, uint64 landedAt) external {
        _states[keccak256(bytes(base))] = PricePairState(price, price, 0, 0, 0, landedAt, landedAt);
    }

    function oraclePricePairState(uint8 oracleType, string calldata base, string calldata quote)
        external
        view
        returns (PricePairState memory s)
    {
        require(oracleType == 14 && keccak256(bytes(quote)) == keccak256("USD"), "no price for oracle was found");
        s = _states[keccak256(bytes(base))];
        require(s.pairPrice != 0, "no price for oracle was found");
    }
}
