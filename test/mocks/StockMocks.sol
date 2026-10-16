// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IExchangeDerivatives} from "../../src/interfaces/IExchangeDerivatives.sol";

/// @notice Stands in for the `0x65` exchange precompile, `vm.etch`ed to its address, with the
/// semantics a stock vault depends on, each as measured or read in the chain's source (v1.20.3):
///
/// - **Balances are 18-decimal.** A subaccount holds an exact `available` and `total`, which fills,
///   fees, payouts and margin moves leave fractional. `subaccountDeposit` answers each ROUNDED TO THE
///   NEAREST unit (half to even), independently, and reverts if either is negative (the ABI cannot
///   pack it). `withdraw` needs the exact available AND total to cover it.
/// - **Orders.** A market order holds its margin plus the fee at its worst price, and fills (or is
///   dropped) at `endBlock`; a reduce-only one (margin 0) holds nothing and is cut to the position.
///   The fee is paid at the fill price; what the hold over-covered comes back, and a sell filled
///   above its worst price pays the extra fee out of its margin. 40% of every fee goes to the
///   relayer, the trader itself when the order names none: its DEFAULT subaccount, whose whole units
///   are swept to the bank (no Transfer event on chain) while the fraction stays there.
/// - **One market order per subaccount, market and block.**
/// - **Funding.** Each market keeps a cumulative funding index, which can go negative; a position
///   records the index it last settled at, and settles the difference (plus `accrueFunding`'s)
///   into its margin on a fill or a margin decrease, never on a read or an increase.
///   `subaccountPositions` REVERTS if any position's recorded index is negative: the precompile
///   packs it as a uint256.
/// - **Market status.** A market that is not active (paused) hides its positions from
///   `subaccountPositions` and refuses orders and margin moves; a cancel still works.
/// - **Market ids** are case-insensitive on the way in and lowercase on the way out.
///
/// `chainLike` turns on the rules the vault must respect but most tests need not model: a minimum
/// notional at the order price, the ticks, a market order refused unless it crosses the book
/// (`setBook`), and a margin decrease refused below 10% of the entry notional.
///
/// Post-only limit orders rest at once, as on chain: checked against the book's best bid and ask
/// and reverted if they would cross, visible to `derivativeOrdersByHashes` in the same transaction,
/// filled as maker by `fillResting` and cancelled by matching with `matchCancel`.
contract MockStockExchange {
    struct Order {
        address sender;
        string subaccountID;
        string marketID;
        bool isBuy;
        uint256 worstPrice;
        uint256 quantity;
        uint256 margin;
        uint256 hold; // 18 decimals, held from the subaccount: the margin plus the fee
    }

    struct Position {
        bool isLong;
        uint256 quantity;
        uint256 entryPrice;
        uint256 margin;
        int256 unsettledFunding;
        int256 fundingEntry;
    }

    struct Resting {
        address sender;
        string subaccountID;
        string marketID;
        bool isBuy;
        uint256 price;
        uint256 quantity;
        uint256 margin;
        uint256 fillable;
        uint256 holdLeft; // 18 decimals, still held for what may fill
    }

    string internal constant NEGATIVE = "abi: negatively-signed value cannot be packed into uint parameter";
    /// @dev A constant, not storage: the mock is `vm.etch`ed, which copies code and no storage.
    uint256 internal constant RELAYER_SHARE_BPS = 4000;

    MockERC20 public cash;
    string public cashDenom;
    uint256 public cashScale; // 10 ** (18 - cash decimals): one cash unit, in 18 decimals

    mapping(bytes32 subaccount => int256) internal _available;
    mapping(bytes32 subaccount => int256) internal _total;
    /// @notice What a trader's default subaccount keeps, 18 decimals: the fraction of a unit left
    /// after its whole units were swept to the bank.
    mapping(address trader => uint256) public defaultDust;

    Order[] internal _pending;
    mapping(bytes32 subaccount => mapping(bytes32 market => Position)) internal _positions;
    mapping(bytes32 subaccount => string[]) internal _markets;
    mapping(bytes32 subaccount => mapping(bytes32 market => bool)) internal _listed;
    mapping(bytes32 subaccountMarket => uint256) internal _lastMarketOrder;
    mapping(bytes32 market => int256) public cumulativeFunding;
    mapping(bytes32 market => bool) public inactive;

    mapping(bytes32 hash => Resting) internal _resting;
    string[] internal _restingHashes;
    uint256 public bestBid;
    uint256 public bestAsk;

    uint256 public feeRate; // 1e18 = 100%
    uint256 public minNotional; // 18 decimals, at the order price
    uint256 public qtyTick;
    uint256 public priceTick;
    bool public enforceCross;
    uint256 public reduceMarginRatio; // 1e18 = 100%
    bool public failDecrease;

    uint256 public ordersPlaced;
    uint256 public limitOrdersPlaced;
    uint256 public cancels;
    uint256 public decreases;

    // ── setup ─────────────────────────────────────────────────────────────

    function setCash(MockERC20 cash_, string calldata denom) external {
        cash = cash_;
        cashDenom = denom;
        cashScale = 10 ** (18 - cash_.decimals());
    }

    /// @notice The rules as on the Helix AAPL perp: a 0.0001% fee, $1 minimum notional, the ticks,
    /// market orders that must cross the book, and margin decreases above 10% of entry notional.
    function chainLike(uint256 qtyTick_, uint256 priceTick_) external {
        feeRate = 1e12;
        minNotional = 1e18;
        (qtyTick, priceTick) = (qtyTick_, priceTick_);
        enforceCross = true;
        reduceMarginRatio = 0.1e18;
    }

    function setFee(uint256 rate) external {
        feeRate = rate;
    }

    function setBook(uint256 bid, uint256 ask) external {
        (bestBid, bestAsk) = (bid, ask);
    }

    function setFailDecrease(bool fail) external {
        failDecrease = fail;
    }

    function setMarketActive(string calldata market, bool active) external {
        inactive[_mkt(market)] = !active;
    }

    function setCumulativeFunding(string calldata market, int256 index) external {
        cumulativeFunding[_mkt(market)] = index;
    }

    /// @notice Funding owed to (positive) or by (negative) a position, not yet in its margin.
    function accrueFunding(string calldata subaccountID, string calldata market, int256 amount) external {
        _positions[keccak256(bytes(subaccountID))][_mkt(market)].unsettledFunding += amount;
    }

    function setMargin(string calldata subaccountID, string calldata market, uint256 margin) external {
        _positions[keccak256(bytes(subaccountID))][_mkt(market)].margin = margin;
    }

    /// @notice Cut a position, as a liquidation would, with nothing else touched.
    function setQuantity(string calldata subaccountID, string calldata market, uint256 quantity) external {
        _positions[keccak256(bytes(subaccountID))][_mkt(market)].quantity = quantity;
    }

    /// @notice Credit `amount` (18 decimals) to a subaccount, as a payout's fraction or anyone's
    /// deposit would.
    function addDust(string calldata subaccountID, uint256 amount) external {
        bytes32 sub = keccak256(bytes(subaccountID));
        _available[sub] += int256(amount);
        _total[sub] += int256(amount);
    }

    // ── subaccount funds ──────────────────────────────────────────────────

    function deposit(address sender, string calldata subaccountID, string calldata denom, uint256 amount)
        external
        returns (bool)
    {
        require(msg.sender == sender, "authz");
        require(amount != 0 && _isCash(denom) && !_isDefault(subaccountID), "deposit");
        cash.burn(sender, amount);
        bytes32 sub = keccak256(bytes(subaccountID));
        _available[sub] += int256(amount * cashScale);
        _total[sub] += int256(amount * cashScale);
        return true;
    }

    function withdraw(address sender, string calldata subaccountID, string calldata denom, uint256 amount)
        external
        returns (bool)
    {
        require(msg.sender == sender, "authz");
        require(_isCash(denom) && !_isDefault(subaccountID), "withdraw");
        bytes32 sub = keccak256(bytes(subaccountID));
        int256 a = int256(amount * cashScale);
        require(_available[sub] >= a && _total[sub] >= a, "withdrawal failed: subaccount has insufficient deposits");
        _available[sub] -= a;
        _total[sub] -= a;
        cash.mint(sender, amount);
        return true;
    }

    function subaccountDeposit(string calldata subaccountID, string calldata denom)
        external
        view
        returns (uint256 available, uint256 total)
    {
        if (!_isCash(denom)) return (0, 0);
        if (_isDefault(subaccountID)) {
            uint256 d = _round(int256(defaultDust[_owner(subaccountID)]));
            return (d, d);
        }
        bytes32 sub = keccak256(bytes(subaccountID));
        return (_round(_available[sub]), _round(_total[sub]));
    }

    /// @notice The whole cash units a subaccount holds, rounded down.
    function depositTotal(bytes32 sub) external view returns (uint256) {
        int256 t = _total[sub];
        return t <= 0 ? 0 : uint256(t) / cashScale;
    }

    /// @notice A subaccount's exact balances, 18 decimals.
    function depositExact(string calldata subaccountID) external view returns (int256 available, int256 total) {
        bytes32 sub = keccak256(bytes(subaccountID));
        return (_available[sub], _total[sub]);
    }

    // ── orders ────────────────────────────────────────────────────────────

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
        bool isBuy = _is(o.orderType, "buy");
        require(isBuy || _is(o.orderType, "sell"), "order type");
        _check(o, isBuy);
        bytes32 key = keccak256(abi.encode(o.subaccountID, _mkt(o.marketID)));
        require(_lastMarketOrder[key] != block.number, "only one market order per block");
        _lastMarketOrder[key] = block.number;
        if (enforceCross) {
            require(
                isBuy ? bestAsk != 0 && o.price >= bestAsk : bestBid != 0 && o.price <= bestBid,
                "slippage exceeds worst price"
            );
        }
        uint256 hold = o.margin == 0 ? 0 : o.margin + _fee(o.price, o.quantity);
        _hold(sender, o.subaccountID, hold);
        _pending.push(Order(sender, o.subaccountID, o.marketID, isBuy, o.price, o.quantity, o.margin, hold));
        ordersPlaced++;
        r.orderHash = "0xmock";
    }

    function createDerivativeLimitOrder(address sender, IExchangeDerivatives.DerivativeOrder calldata o)
        external
        returns (IExchangeDerivatives.CreateDerivativeLimitOrderResponse memory r)
    {
        require(msg.sender == sender, "authz");
        bool isBuy = _is(o.orderType, "buyPostOnly");
        require(isBuy || _is(o.orderType, "sellPostOnly"), "order type");
        _check(o, isBuy);
        require(isBuy ? (bestAsk == 0 || o.price < bestAsk) : o.price > bestBid, "exceeds top of book");
        uint256 hold = o.margin == 0 ? 0 : o.margin + _fee(o.price, o.quantity);
        _hold(sender, o.subaccountID, hold);
        r.orderHash = Strings.toHexString(uint256(keccak256(abi.encode(address(this), ++limitOrdersPlaced))), 32);
        _resting[keccak256(bytes(r.orderHash))] =
            Resting(sender, o.subaccountID, o.marketID, isBuy, o.price, o.quantity, o.margin, o.quantity, hold);
        _restingHashes.push(r.orderHash);
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
        require(_resting[keccak256(bytes(orderHash))].fillable != 0, "order doesnt exist");
        _drop(orderHash);
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

    /// @notice Fill every pending order at `fillPrice` if its worst price allows and its market is
    /// still active, else drop it and release its hold.
    function endBlock(uint256 fillPrice) external {
        for (uint256 k; k < _pending.length; ++k) {
            Order memory o = _pending[k];
            bool fills = o.isBuy ? fillPrice <= o.worstPrice : fillPrice >= o.worstPrice;
            if (!fills || inactive[_mkt(o.marketID)] || !_canFill(o)) {
                _release(o.sender, o.subaccountID, o.hold);
                continue;
            }
            _fill(o, fillPrice);
        }
        delete _pending;
    }

    /// @notice Fill `quantity` of a resting order at its own price, as the EndBlocker would match
    /// a taker against it.
    function fillResting(string calldata orderHash, uint256 quantity) external {
        Resting storage o = _resting[keccak256(bytes(orderHash))];
        require(quantity <= o.fillable, "overfill");
        uint256 marginShare = o.margin * quantity / o.quantity;
        uint256 holdShare = o.holdLeft * quantity / o.fillable;
        o.holdLeft -= holdShare;
        o.fillable -= quantity;
        _fill(Order(o.sender, o.subaccountID, o.marketID, o.isBuy, o.price, quantity, marginShare, holdShare), o.price);
    }

    /// @notice Drop a resting order unfilled, as matching does when it fails a margin check; the
    /// rest of its hold comes back.
    function matchCancel(string calldata orderHash) external {
        _drop(orderHash);
    }

    // ── positions ─────────────────────────────────────────────────────────

    function increasePositionMargin(
        address sender,
        string calldata src,
        string calldata dst,
        string calldata market,
        uint256 amount
    ) external returns (bool) {
        require(msg.sender == sender, "authz");
        bytes32 mkt = _mkt(market);
        require(!inactive[mkt], "market not active");
        _debit(sender, src, amount);
        _positions[keccak256(bytes(dst))][mkt].margin += amount;
        return true;
    }

    /// @notice As on chain: settles the position's funding first, then moves `amount`, if what stays
    /// is at least `reduceMarginRatio` of the entry notional.
    function decreasePositionMargin(
        address sender,
        string calldata src,
        string calldata dst,
        string calldata market,
        uint256 amount
    ) external returns (bool) {
        require(msg.sender == sender, "authz");
        require(!failDecrease, "decrease failed");
        bytes32 mkt = _mkt(market);
        require(!inactive[mkt], "market not active");
        Position storage p = _positions[keccak256(bytes(src))][mkt];
        require(p.quantity != 0, "no position");
        _settleFunding(p, mkt);
        require(p.margin >= amount, "margin");
        p.margin -= amount;
        require(p.margin >= p.entryPrice * p.quantity / 1e18 * reduceMarginRatio / 1e18, "below reduce margin ratio");
        _credit(sender, dst, amount);
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
            if (_shown(sub, markets[k])) n++;
        }
        out = new IExchangeDerivatives.DerivativePosition[](n);
        uint256 j;
        for (uint256 k; k < markets.length; ++k) {
            if (!_shown(sub, markets[k])) continue;
            Position storage p = _positions[sub][keccak256(bytes(markets[k]))];
            require(p.fundingEntry >= 0, NEGATIVE);
            // Raw state, as on chain: margin without the unsettled funding.
            out[j++] = IExchangeDerivatives.DerivativePosition({
                subaccountID: subaccountID,
                marketID: markets[k],
                isLong: p.isLong,
                quantity: p.quantity,
                entryPrice: p.entryPrice,
                margin: p.margin,
                // forge-lint: disable-next-line(unsafe-typecast) - checked above.
                cumulativeFundingEntry: uint256(p.fundingEntry)
            });
        }
    }

    /// @notice As a governance forced settlement: resting orders cancelled, the position closed at
    /// `price` with its funding, margin plus PnL paid to the subaccount (`holder`'s default one for
    /// a default subaccount).
    function forceSettle(string calldata subaccountID, string calldata market, uint256 price, address holder) external {
        bytes32 mkt = _mkt(market);
        _dropAll(subaccountID, mkt);
        Position storage p = _positions[keccak256(bytes(subaccountID))][mkt];
        _settleFunding(p, mkt);
        int256 move = p.isLong ? int256(price) - int256(p.entryPrice) : int256(p.entryPrice) - int256(price);
        int256 payout = int256(p.margin) + move * int256(p.quantity) / 1e18;
        (p.quantity, p.margin) = (0, 0);
        if (payout > 0) _credit(holder, subaccountID, uint256(payout));
    }

    /// @notice As a liquidation: resting orders cancelled, the position gone, and a `deficit` (18
    /// decimals) the insurance fund did not cover taken from what the subaccount has available.
    function liquidate(string calldata subaccountID, string calldata market, uint256 deficit) external {
        bytes32 mkt = _mkt(market);
        _dropAll(subaccountID, mkt);
        Position storage p = _positions[keccak256(bytes(subaccountID))][mkt];
        (p.quantity, p.margin, p.unsettledFunding) = (0, 0, 0);
        bytes32 sub = keccak256(bytes(subaccountID));
        _available[sub] -= int256(deficit);
        _total[sub] -= int256(deficit);
    }

    // ── internals ─────────────────────────────────────────────────────────

    function _check(IExchangeDerivatives.DerivativeOrder calldata o, bool isBuy) internal view {
        bytes32 mkt = _mkt(o.marketID);
        require(!inactive[mkt], "market not active");
        require(o.quantity != 0 && o.price != 0, "zero");
        require(qtyTick == 0 || o.quantity % qtyTick == 0, "invalid quantity tick");
        require(priceTick == 0 || o.price % priceTick == 0, "invalid price tick");
        require(o.quantity * o.price / 1e18 >= minNotional, "order notional below min notional");
        if (o.margin == 0) {
            Position storage p = _positions[keccak256(bytes(o.subaccountID))][mkt];
            require(p.quantity != 0 && p.isLong != isBuy, "no position to reduce");
        }
    }

    /// @dev A reduce-only order with nothing left to reduce is dropped.
    function _canFill(Order memory o) internal view returns (bool) {
        if (o.margin != 0) return true;
        Position storage p = _positions[keccak256(bytes(o.subaccountID))][_mkt(o.marketID)];
        return p.quantity != 0 && p.isLong != o.isBuy;
    }

    function _fill(Order memory o, uint256 price) internal {
        bytes32 sub = keccak256(bytes(o.subaccountID));
        bytes32 mkt = _mkt(o.marketID);
        Position storage p = _positions[sub][mkt];
        if (!_listed[sub][mkt]) {
            _listed[sub][mkt] = true;
            _markets[sub].push(_lower(o.marketID));
        }
        _settleFunding(p, mkt);
        if (p.quantity == 0 || p.isLong == o.isBuy) {
            require(o.margin != 0, "reduce-only with no position");
            uint256 fee = _fee(price, o.quantity);
            _relayer(o.sender, fee);
            p.entryPrice = (p.entryPrice * p.quantity + price * o.quantity) / (p.quantity + o.quantity);
            p.quantity += o.quantity;
            p.isLong = o.isBuy;
            // What the hold over-covered comes back; a fee above it comes out of the margin.
            uint256 margin = o.margin < o.hold ? o.margin : o.hold;
            uint256 back = o.hold - margin;
            if (fee > back) (margin, back) = (margin - (fee - back), 0);
            else back -= fee;
            p.margin += margin;
            _spend(o.sender, o.subaccountID, o.hold, back);
            return;
        }
        require(o.margin == 0 || o.quantity <= p.quantity, "flip");
        uint256 q = o.quantity < p.quantity ? o.quantity : p.quantity;
        uint256 closeFee = _fee(price, q);
        _relayer(o.sender, closeFee);
        uint256 marginShare = p.margin * q / p.quantity;
        int256 move = p.isLong ? int256(price) - int256(p.entryPrice) : int256(p.entryPrice) - int256(price);
        int256 payout = int256(marginShare) + move * int256(q) / 1e18 - int256(closeFee);
        p.quantity -= q;
        p.margin -= marginShare;
        _spend(o.sender, o.subaccountID, o.hold, o.hold);
        if (payout > 0) _credit(o.sender, o.subaccountID, uint256(payout));
    }

    function _settleFunding(Position storage p, bytes32 mkt) internal {
        if (p.quantity != 0) {
            int256 f = (cumulativeFunding[mkt] - p.fundingEntry) * int256(p.quantity) / 1e18;
            int256 m = int256(p.margin) + p.unsettledFunding + (p.isLong ? -f : f);
            p.margin = m > 0 ? uint256(m) : 0;
        }
        p.unsettledFunding = 0;
        p.fundingEntry = cumulativeFunding[mkt];
    }

    function _shown(bytes32 sub, string storage market) internal view returns (bool) {
        bytes32 mkt = keccak256(bytes(market));
        return _positions[sub][mkt].quantity != 0 && !inactive[mkt];
    }

    function _fee(uint256 price, uint256 quantity) internal view returns (uint256) {
        return price * quantity / 1e18 * feeRate / 1e18;
    }

    /// @dev The relayer's share of a fee, to the trader's default subaccount: whole units swept to
    /// the bank, the fraction kept.
    function _relayer(address trader, uint256 fee) internal {
        _creditDefault(trader, fee * RELAYER_SHARE_BPS / 10_000);
    }

    function _creditDefault(address trader, uint256 amount) internal {
        uint256 d = defaultDust[trader] + amount;
        uint256 whole = d / cashScale;
        defaultDust[trader] = d - whole * cashScale;
        if (whole != 0) cash.mint(trader, whole);
    }

    function _drop(string memory orderHash) internal {
        Resting storage o = _resting[keccak256(bytes(orderHash))];
        _release(o.sender, o.subaccountID, o.holdLeft);
        delete _resting[keccak256(bytes(orderHash))];
    }

    function _dropAll(string calldata subaccountID, bytes32 mkt) internal {
        for (uint256 k; k < _restingHashes.length; ++k) {
            Resting storage o = _resting[keccak256(bytes(_restingHashes[k]))];
            if (o.fillable == 0 || _mkt(o.marketID) != mkt) continue;
            if (keccak256(bytes(o.subaccountID)) != keccak256(bytes(subaccountID))) continue;
            _drop(_restingHashes[k]);
        }
    }

    /// @dev Held for an order: the bank pays it at once for a default subaccount.
    function _hold(address sender, string memory subaccountID, uint256 amount) internal {
        if (amount == 0) return;
        if (_isDefault(subaccountID)) {
            cash.burn(sender, (amount + cashScale - 1) / cashScale);
            return;
        }
        bytes32 sub = keccak256(bytes(subaccountID));
        require(_available[sub] >= int256(amount), "insufficient funds");
        _available[sub] -= int256(amount);
    }

    /// @dev A hold given back unfilled.
    function _release(address sender, string memory subaccountID, uint256 amount) internal {
        if (amount == 0) return;
        if (_isDefault(subaccountID)) {
            _creditDefault(sender, amount);
            return;
        }
        _available[keccak256(bytes(subaccountID))] += int256(amount);
    }

    /// @dev A hold used by a fill, `back` of it returned.
    function _spend(address sender, string memory subaccountID, uint256 hold, uint256 back) internal {
        if (_isDefault(subaccountID)) {
            if (back != 0) _creditDefault(sender, back);
            return;
        }
        bytes32 sub = keccak256(bytes(subaccountID));
        _total[sub] -= int256(hold);
        _available[sub] += int256(back);
        _total[sub] += int256(back);
    }

    function _credit(address owner, string memory subaccountID, uint256 amount) internal {
        if (amount == 0) return;
        if (_isDefault(subaccountID)) {
            _creditDefault(owner, amount);
            return;
        }
        bytes32 sub = keccak256(bytes(subaccountID));
        _available[sub] += int256(amount);
        _total[sub] += int256(amount);
    }

    function _debit(address sender, string memory subaccountID, uint256 amount) internal {
        if (amount == 0) return;
        if (_isDefault(subaccountID)) {
            cash.burn(sender, (amount + cashScale - 1) / cashScale);
            return;
        }
        bytes32 sub = keccak256(bytes(subaccountID));
        require(_available[sub] >= int256(amount), "insufficient funds");
        _available[sub] -= int256(amount);
        _total[sub] -= int256(amount);
    }

    /// @dev An 18-decimal balance in cash units, rounded to the nearest, half to even, as
    /// `LegacyDec.RoundInt`; negative cannot be packed.
    function _round(int256 v) internal view returns (uint256 q) {
        require(v >= 0, NEGATIVE);
        // forge-lint: disable-next-line(unsafe-typecast) - checked above.
        uint256 u = uint256(v);
        q = u / cashScale;
        uint256 r = u % cashScale;
        if (r * 2 > cashScale || (r * 2 == cashScale && q % 2 == 1)) q++;
    }

    function _isCash(string calldata denom) internal view returns (bool) {
        return keccak256(bytes(denom)) == keccak256(bytes(cashDenom));
    }

    function _is(string calldata a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _mkt(string memory market) internal pure returns (bytes32) {
        return keccak256(bytes(_lower(market)));
    }

    function _lower(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length);
        for (uint256 k; k < b.length; ++k) {
            bytes1 ch = b[k];
            out[k] = ch >= "A" && ch <= "Z" ? bytes1(uint8(ch) + 32) : ch;
        }
        return string(out);
    }

    /// @dev A default subaccount id ends in a zero nonce.
    function _isDefault(string memory subaccountID) internal pure returns (bool) {
        bytes memory b = bytes(subaccountID);
        for (uint256 k = 42; k < b.length; ++k) {
            if (b[k] != "0") return false;
        }
        return true;
    }

    /// @dev The trader a subaccount id belongs to: its first 20 bytes.
    function _owner(string calldata subaccountID) internal pure returns (address a) {
        bytes memory b = bytes(subaccountID);
        uint160 v;
        for (uint256 k = 2; k < 42; ++k) {
            uint8 c = uint8(b[k]);
            v = v * 16 + (c >= 97 ? c - 87 : c >= 65 ? c - 55 : c - 48);
        }
        a = address(v);
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
