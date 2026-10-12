// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IExchangeDerivatives} from "../../src/interfaces/IExchangeDerivatives.sol";
import {IOracleModule} from "../../src/interfaces/IOracleModule.sol";

/// @notice Stands in for the `0x67` oracle precompile, `vm.etch`ed to its address. A feed that was
/// never set reverts, as the real one does.
contract MockOraclePrecompile {
    struct Feed {
        uint256 price;
        uint64 timestamp;
    }

    mapping(bytes32 feed => Feed) internal _feeds;

    function set(string calldata feed, uint256 price, uint64 timestamp) external {
        _feeds[keccak256(bytes(feed))] = Feed(price, timestamp);
    }

    function oraclePricePairState(uint8, string calldata base, string calldata)
        external
        view
        returns (IOracleModule.PricePairState memory s)
    {
        Feed memory f = _feeds[keccak256(bytes(base))];
        require(f.timestamp != 0, "price not found");
        s.pairPrice = f.price;
        s.basePrice = f.price;
        s.baseTimestamp = f.timestamp;
        s.quoteTimestamp = f.timestamp;
    }
}

/// @notice Stands in for the `0x65` exchange precompile, `vm.etch`ed to its address, with the
/// semantics the vault depends on: an order only holds margin when placed; it fills (or is
/// dropped) at `endBlock`, against the price the test names; positions are per subaccount.
/// Margin moves by minting and burning the cash mock, which is how the real precompile debits a
/// bank balance without an approval.
contract MockExchangePrecompile {
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
    }

    MockERC20 public cash;
    uint256 public cashScale; // 10 ** (18 - cash decimals)
    Order[] internal _pending;
    mapping(bytes32 subaccount => mapping(bytes32 market => Position)) internal _positions;
    mapping(bytes32 subaccount => string[]) internal _markets;
    uint256 public ordersPlaced;

    function setCash(MockERC20 cash_) external {
        cash = cash_;
        cashScale = 10 ** (18 - cash_.decimals());
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

    /// @notice Fill every pending order at `fillPrice` if its worst price allows, else drop it
    /// and release its margin.
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
        // Reducing (the vault only ever reduces a short with a reduce-only buy).
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

    /// @notice Move a position's margin by `delta` (funding, a liquidation scare), for tests.
    function setMargin(string calldata subaccountID, string calldata market, uint256 margin) external {
        _positions[keccak256(bytes(subaccountID))][keccak256(bytes(market))].margin = margin;
    }

    function _toCash(uint256 api, bool up) internal view returns (uint256) {
        return up ? (api + cashScale - 1) / cashScale : api / cashScale;
    }
}
