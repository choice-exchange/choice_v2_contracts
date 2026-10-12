// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {IExchangeDerivatives} from "../interfaces/IExchangeDerivatives.sol";
import {IOracleModule} from "../interfaces/IOracleModule.sol";
import {SubaccountLib} from "../libraries/SubaccountLib.sol";

/// @notice An issued asset's terms in a `BasketVault`. Caps are in cash units; prices and
/// quantities in the exchange's 1e18 format.
/// @param qtyTick the perpetual market's quantity tick, 1e18 = one whole asset unit
/// @param priceTick the perpetual market's price tick, in 1e18 cash per whole unit
/// @param leverageX10 hedge leverage times ten: margin = notional * 10 / leverageX10
/// @param hedgeSlippageBps how far from the oracle a hedge order may fill (its worst price)
/// @param targetCash the inventory the basket aims to hold, in cash units; zero means no target
/// @param skewBps how far the fill price leans toward the target at a full deviation (holding
/// nothing, or twice the target). Below `minSpreadBps`, so a fill never crosses the oracle.
struct AssetConfig {
    address token;
    uint8 oracleType;
    bool enabled;
    uint16 spreadBps;
    uint16 minSpreadBps;
    uint16 maxSpreadBps;
    uint16 leverageX10;
    uint16 maxJumpBps;
    uint16 hedgeSlippageBps;
    uint32 maxAge;
    uint64 qtyTick;
    uint64 priceTick;
    uint96 maxTradeCash;
    uint96 maxInventoryCash;
    uint96 maxUnhedgedCash;
    uint96 windowCap;
    uint96 minHedgeCash;
    uint96 targetCash;
    uint16 skewBps;
    string feedId;
    string marketId;
}

/// @param lastPrice the oracle price of the last fill, hedge or reset: the jump breaker's anchor
/// @param expectedShort the short the last hedge order aimed for, in 1e18 units
struct AssetState {
    uint128 lastPrice;
    uint64 lastHedgeBlock;
    uint64 windowStart;
    uint96 windowUsed;
    uint8 decimals;
    bool assetIsCurrency0;
    bool poolRegistered;
    int128 expectedShort;
    PoolId poolId;
}

/// @notice What the library needs of the vault it runs inside.
struct BasketContext {
    IVault vault;
    Currency cash;
    uint8 cashDecimals;
}

/// @notice The vault-wide settings a fill is checked against.
struct FillEnv {
    bool paused;
    uint32 outflowWindow;
    uint256 cashReserve;
}

/// @notice Why a swap fell through to the curve.
enum Refusal {
    None,
    Paused,
    Disabled,
    Stale,
    Jump,
    Size,
    Window,
    Inventory,
    InventoryCap,
    Reserve,
    Unhedged,
    PriceLimit
}

/// @title BasketLib
/// @notice The hedge and the valuation of a `BasketVault`, kept out of the vault's own bytecode.
/// Its external functions run by DELEGATECALL, so they act as the vault: the perpetual position
/// they open is the vault's, the vault lock they take calls the vault back, and their events are
/// the vault's events.
library BasketLib {
    using SafeCast for uint256;
    using SafeCast for int256;

    IOracleModule internal constant ORACLE = IOracleModule(0x0000000000000000000000000000000000000067);
    IExchangeDerivatives internal constant EXCHANGE = IExchangeDerivatives(0x0000000000000000000000000000000000000065);
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_ASSETS = 8;

    /// @dev Transient: set only while the vault holds a vault lock it opened itself.
    uint256 internal constant LOCK_OPEN_SLOT = 0x9f4b7e2a2c0e1f5e6b9a8d7c6f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c;
    uint8 internal constant OP_TO_CLAIMS = 1;
    uint8 internal constant OP_FROM_CLAIMS = 2;

    error StaleOracle(uint256 index);
    error OracleMissing();
    error BadConfig();
    error TooManyAssets();
    error TokenChangeAfterPool(uint256 index);
    error NotIssuable(address token);
    error SpreadOutOfBounds(uint16 spreadBps, uint16 minSpreadBps, uint16 maxSpreadBps);
    error HedgePending(uint256 index);
    error NothingToHedge(uint256 index, int256 gap);
    error MarginHealthy(uint256 index);

    event HedgeOrdered(
        uint256 indexed index, bool sell, uint256 quantity, uint256 worstPrice, uint256 margin, string orderHash
    );
    event MarginAdded(uint256 indexed index, uint256 amount);
    event AssetAdded(uint256 indexed index, address indexed token, string feedId, string marketId);
    event AssetUpdated(uint256 indexed index);

    // -------------------------------------------------------------------------------------
    // External (delegatecalled by the vault)
    // -------------------------------------------------------------------------------------

    /// @notice Move asset `i`'s short toward the vault's holding of it, in one market order: a
    /// sell posting margin at the asset's leverage, or a reduce-only buy. The worst price is the
    /// oracle price moved by the hedge slippage, on the market's price tick.
    function syncHedge(AssetConfig storage c, AssetState storage s, uint256 i, BasketContext memory ctx)
        external
        returns (string memory)
    {
        if (s.lastHedgeBlock == block.number) revert HedgePending(i);
        (bool fresh, uint256 price) = oracle(c);
        if (!fresh) revert StaleOracle(i);

        (bool found, IExchangeDerivatives.DerivativePosition memory p) =
            find(EXCHANGE.subaccountPositions(subaccount()), c.marketId);
        int256 current = !found ? int256(0) : (p.isLong ? -p.quantity.toInt256() : p.quantity.toInt256());
        uint256 heldUnits = toUnits(holding(ctx, Currency.wrap(c.token)), s.decimals);
        int256 gap = (heldUnits / c.qtyTick * c.qtyTick).toInt256() - current;
        bool sell = gap > 0;
        // A buy only ever reduces a short; it never opens a long.
        // forge-lint: disable-next-line(unsafe-typecast) - each side's sign is tested first.
        uint256 qty = sell ? uint256(gap) : Math.min(uint256(-gap), current > 0 ? uint256(current) : 0);
        if (qty == 0 || unitsToCash(ctx, qty, price) < c.minHedgeCash) revert NothingToHedge(i, gap);

        uint256 worst = sell
            ? price * (BPS - c.hedgeSlippageBps) / BPS / c.priceTick * c.priceTick
            : Math.ceilDiv(Math.mulDiv(price, BPS + c.hedgeSlippageBps, BPS, Math.Rounding.Ceil), c.priceTick)
                * c.priceTick;
        uint256 margin = sell ? Math.mulDiv(qty, worst, 1e18) * 10 / c.leverageX10 : 0;
        // The margin hold also covers the taker fee; 1% over is far above any fee tier.
        if (margin != 0) ensureToken(ctx, ctx.cash, fromApi(ctx, margin, Math.Rounding.Ceil) * 101 / 100 + 1);

        string memory orderHash =
            EXCHANGE.createDerivativeMarketOrder(
            address(this),
            IExchangeDerivatives.DerivativeOrder({
                marketID: c.marketId,
                subaccountID: subaccount(),
                feeRecipient: "",
                price: worst,
                quantity: qty,
                cid: "",
                orderType: sell ? "sell" : "buy",
                margin: margin,
                triggerPrice: 0
            })
        )
        .orderHash;
        s.lastHedgeBlock = uint64(block.number);
        s.expectedShort = (sell ? current + qty.toInt256() : current - qty.toInt256()).toInt128();
        s.lastPrice = price.toUint128();
        emit HedgeOrdered(i, sell, qty, worst, margin, orderHash);
        return orderHash;
    }

    /// @notice Bring asset `i`'s short back to its target leverage once its margin is below 70%
    /// of what that leverage needs at the current price.
    function topUpMargin(AssetConfig storage c, uint256 i, BasketContext memory ctx) external {
        (bool found, IExchangeDerivatives.DerivativePosition memory p) =
            find(EXCHANGE.subaccountPositions(subaccount()), c.marketId);
        if (!found) revert MarginHealthy(i);
        uint256 target = Math.mulDiv(p.quantity, markPrice(c), 1e18) * 10 / c.leverageX10;
        if (p.margin * 10 >= target * 7) revert MarginHealthy(i);
        uint256 amount = target - p.margin;
        ensureToken(ctx, ctx.cash, fromApi(ctx, amount, Math.Rounding.Ceil) + 1);
        string memory sub = subaccount();
        EXCHANGE.increasePositionMargin(address(this), sub, sub, c.marketId, amount);
        emit MarginAdded(i, amount);
    }

    /// @notice Every asset at its oracle price plus every short at margin + PnL, in cash units.
    /// ⚠️ Funding reaches a position's margin only when it settles, so accrued funding is not
    /// counted until then.
    function basketValue(
        AssetConfig[] storage configs,
        mapping(uint256 => AssetState) storage states,
        BasketContext memory ctx
    ) external view returns (uint256 total) {
        IExchangeDerivatives.DerivativePosition[] memory positions = EXCHANGE.subaccountPositions(subaccount());
        uint256 n = configs.length;
        for (uint256 i; i < n; ++i) {
            AssetConfig storage c = configs[i];
            uint256 held = holding(ctx, Currency.wrap(c.token));
            (bool found, IExchangeDerivatives.DerivativePosition memory p) = find(positions, c.marketId);
            if (held == 0 && !found) continue;
            uint256 price = markPrice(c);
            total += assetToCash(ctx, held, price, states[i].decimals, Math.Rounding.Floor);
            if (found) total += positionValue(ctx, p, price);
        }
    }

    /// @notice The fill for one swap, or the reason there is none. Every amount rounds the vault's
    /// way: output down, input up.
    /// @param cashIn true when the taker pays cash for the asset
    /// @param amountSpecified the input on exact input, the output on exact output
    /// @param zeroForOne and `sqrtPriceLimitX96`: the swap's own, so its price limit binds the fill
    function quote(
        AssetConfig storage c,
        AssetState storage s,
        BasketContext memory ctx,
        FillEnv memory env,
        bool cashIn,
        uint256 amountSpecified,
        bool exactInput,
        bool zeroForOne,
        uint160 sqrtPriceLimitX96
    ) external view returns (uint256 amountIn, uint256 amountOut, uint256 price, Refusal) {
        if (env.paused) return (0, 0, 0, Refusal.Paused);
        if (!c.enabled || !s.poolRegistered) return (0, 0, 0, Refusal.Disabled);
        bool fresh;
        (fresh, price) = oracle(c);
        if (!fresh) return (0, 0, price, Refusal.Stale);
        if (s.lastPrice != 0 && deviationBps(price, s.lastPrice) > c.maxJumpBps) return (0, 0, price, Refusal.Jump);

        uint256 scale = 10 ** (uint256(s.decimals) + 18 - ctx.cashDecimals);
        // Lean both sides toward the target: short of it, the asset costs more and fetches more.
        int256 lean = skew(c, s, ctx, price);
        if (cashIn) {
            // forge-lint: disable-next-line(unsafe-typecast) - |lean| < minSpreadBps <= spreadBps.
            uint256 ask = Math.mulDiv(price, uint256(int256(BPS + c.spreadBps) + lean), BPS, Math.Rounding.Ceil);
            (amountIn, amountOut) = exactInput
                ? (amountSpecified, Math.mulDiv(amountSpecified, scale, ask))
                : (Math.mulDiv(amountSpecified, ask, scale, Math.Rounding.Ceil), amountSpecified);
        } else {
            // forge-lint: disable-next-line(unsafe-typecast) - |lean| < minSpreadBps <= spreadBps < BPS.
            uint256 bid = price * uint256(int256(BPS - c.spreadBps) + lean) / BPS;
            (amountIn, amountOut) = exactInput
                ? (amountSpecified, Math.mulDiv(amountSpecified, bid, scale))
                : (Math.mulDiv(amountSpecified, scale, bid, Math.Rounding.Ceil), amountSpecified);
        }
        Refusal r = guards(c, s, ctx, env, cashIn, amountIn, amountOut, price);
        if (r == Refusal.None && !withinLimit(zeroForOne, amountIn, amountOut, sqrtPriceLimitX96)) {
            r = Refusal.PriceLimit;
        }
        if (r != Refusal.None) return (0, 0, price, r);
        return (amountIn, amountOut, price, Refusal.None);
    }

    /// @notice How far asset `i` is from its target, in cash units at the oracle price: positive
    /// when the basket should buy more from the issuer, negative when it should sell some back.
    function rebalanceGap(AssetConfig storage c, AssetState storage s, BasketContext memory ctx)
        external
        view
        returns (int256)
    {
        if (c.targetCash == 0) return 0;
        uint256 held =
            assetToCash(ctx, holding(ctx, Currency.wrap(c.token)), markPrice(c), s.decimals, Math.Rounding.Floor);
        return int256(uint256(c.targetCash)) - held.toInt256();
    }

    /// @notice Revert unless every enabled asset's oracle is fresh: shares are priced off it.
    function requireFresh(AssetConfig[] storage configs) external view {
        uint256 n = configs.length;
        for (uint256 i; i < n; ++i) {
            if (!configs[i].enabled) continue;
            (bool fresh,) = oracle(configs[i]);
            if (!fresh) revert StaleOracle(i);
        }
    }

    /// @notice Add an asset (`i == type(uint256).max`) or replace asset `i`'s terms. An asset's
    /// token is fixed once its pool exists.
    function setAsset(
        AssetConfig[] storage configs,
        mapping(uint256 => AssetState) storage states,
        uint256 i,
        AssetConfig calldata c,
        address cash
    ) external returns (uint256) {
        bool adding = i == type(uint256).max;
        if (adding) {
            if (configs.length == MAX_ASSETS) revert TooManyAssets();
        } else if (states[i].poolRegistered && c.token != configs[i].token) {
            revert TokenChangeAfterPool(i);
        }
        checkConfig(configs, c, i, cash);
        if (adding) {
            i = configs.length;
            configs.push(c);
            emit AssetAdded(i, c.token, c.feedId, c.marketId);
        } else {
            configs[i] = c;
            emit AssetUpdated(i);
        }
        states[i].decimals = IERC20Metadata(c.token).decimals();
        return i;
    }

    /// @notice `amount` of `token` in cash units: itself for cash, its oracle value for an asset.
    function cashValue(
        AssetConfig[] storage configs,
        mapping(uint256 => AssetState) storage states,
        BasketContext memory ctx,
        address token,
        uint256 amount
    ) external view returns (uint256) {
        if (token == Currency.unwrap(ctx.cash)) return amount;
        for (uint256 i; i < configs.length; ++i) {
            if (configs[i].token == token) {
                return assetToCash(ctx, amount, markPrice(configs[i]), states[i].decimals, Math.Rounding.Ceil);
            }
        }
        revert NotIssuable(token);
    }

    /// @notice Refuse terms the vault cannot work with.
    /// @param self the index being updated, or `type(uint256).max` for a new asset
    function checkConfig(AssetConfig[] storage configs, AssetConfig calldata c, uint256 self, address cash)
        public
        view
    {
        if (c.token == address(0) || c.token == cash) revert BadConfig();
        for (uint256 j; j < configs.length; ++j) {
            if (j != self && configs[j].token == c.token) revert BadConfig();
        }
        if (c.leverageX10 < 10 || c.qtyTick == 0 || c.priceTick == 0 || c.maxAge == 0) revert BadConfig();
        if (c.minSpreadBps > c.maxSpreadBps || c.maxSpreadBps >= BPS || c.hedgeSlippageBps >= BPS) revert BadConfig();
        if (c.spreadBps < c.minSpreadBps || c.spreadBps > c.maxSpreadBps) {
            revert SpreadOutOfBounds(c.spreadBps, c.minSpreadBps, c.maxSpreadBps);
        }
        // The lean must stay inside the spread, so neither side ever crosses the oracle.
        if (c.skewBps != 0 && (c.skewBps >= c.minSpreadBps || c.targetCash == 0)) revert BadConfig();
        if (c.targetCash > c.maxInventoryCash) revert BadConfig();
        if (bytes(c.feedId).length == 0 || bytes(c.marketId).length == 0) revert BadConfig();
    }

    // -------------------------------------------------------------------------------------
    // Internal (inlined into whichever side calls them)
    // -------------------------------------------------------------------------------------

    /// @dev Every guard a fill must pass beyond the oracle. A failure is a refusal, never a revert.
    function guards(
        AssetConfig storage c,
        AssetState storage s,
        BasketContext memory ctx,
        FillEnv memory env,
        bool cashIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 price
    ) internal view returns (Refusal) {
        uint256 cashLeg = cashIn ? amountIn : amountOut;
        if (amountIn == 0 || amountOut == 0 || cashLeg > c.maxTradeCash) return Refusal.Size;

        uint256 outValue = cashIn ? assetToCash(ctx, amountOut, price, s.decimals, Math.Rounding.Ceil) : amountOut;
        uint256 used = block.timestamp >= uint256(s.windowStart) + env.outflowWindow ? 0 : s.windowUsed;
        if (used + outValue > c.windowCap) return Refusal.Window;

        Currency asset = Currency.wrap(c.token);
        // Fills pay out of claims only.
        if (ctx.vault.balanceOf(address(this), cashIn ? asset : ctx.cash) < amountOut) return Refusal.Inventory;

        uint256 held = holding(ctx, asset);
        uint256 heldAfter = cashIn ? held - amountOut : held + amountIn;
        if (!cashIn) {
            if (assetToCash(ctx, heldAfter, price, s.decimals, Math.Rounding.Ceil) > c.maxInventoryCash) {
                return Refusal.InventoryCap;
            }
            // The cash left must still cover the reserve plus the margin to hedge what comes in.
            uint256 marginNeeded =
                assetToCash(ctx, amountIn, price, s.decimals, Math.Rounding.Ceil) * 10 / c.leverageX10;
            if (holding(ctx, ctx.cash) < amountOut + env.cashReserve + marginNeeded) return Refusal.Reserve;
        }

        // Holdings may run ahead of the short only so far, unless this fill narrows the gap.
        uint256 gapBefore = absDiff(toUnits(held, s.decimals), s.expectedShort);
        uint256 gapAfter = absDiff(toUnits(heldAfter, s.decimals), s.expectedShort);
        if (gapAfter > gapBefore && unitsToCash(ctx, gapAfter, price) > c.maxUnhedgedCash) return Refusal.Unhedged;
        return Refusal.None;
    }

    /// @dev The lean in bps, from the holding before the fill: `+skewBps` holding nothing,
    /// `-skewBps` holding twice the target or more, zero on target or with no target.
    function skew(AssetConfig storage c, AssetState storage s, BasketContext memory ctx, uint256 price)
        internal
        view
        returns (int256)
    {
        if (c.skewBps == 0) return 0;
        uint256 held = assetToCash(ctx, holding(ctx, Currency.wrap(c.token)), price, s.decimals, Math.Rounding.Floor);
        int256 deviation =
            (int256(uint256(c.targetCash)) - held.toInt256()) * int256(BPS) / int256(uint256(c.targetCash));
        if (deviation < -int256(BPS)) deviation = -int256(BPS);
        return deviation * int256(uint256(c.skewBps)) / int256(BPS);
    }

    /// @dev The swapper's price limit, applied to the fill's own rate. A limit at either end of
    /// the price range is the routers' "no limit" and always passes.
    function withinLimit(bool zeroForOne, uint256 amountIn, uint256 amountOut, uint160 sqrtPriceLimitX96)
        internal
        pure
        returns (bool)
    {
        if (sqrtPriceLimitX96 <= TickMath.MIN_SQRT_RATIO + 1 || sqrtPriceLimitX96 >= TickMath.MAX_SQRT_RATIO - 1) {
            return true;
        }
        // limit = currency1 per currency0, as a Q96 price
        uint256 limitX96 = Math.mulDiv(sqrtPriceLimitX96, sqrtPriceLimitX96, 1 << 96);
        // Selling currency0, the rate (out1 / in0) may not fall below the limit; buying it, the
        // rate (in1 / out0) may not rise above it.
        return zeroForOne
            ? amountOut >= Math.mulDiv(amountIn, limitX96, 1 << 96)
            : amountIn <= Math.mulDiv(amountOut, limitX96, 1 << 96);
    }

    function deviationBps(uint256 price, uint256 anchor) internal pure returns (uint256) {
        uint256 d = price > anchor ? price - anchor : anchor - price;
        return d * BPS / anchor;
    }

    function absDiff(uint256 a, int128 b) internal pure returns (uint256) {
        int256 d = a.toInt256() - int256(b);
        // forge-lint: disable-next-line(unsafe-typecast) - magnitude of a signed value.
        return d < 0 ? uint256(-d) : uint256(d);
    }

    /// @return fresh whether the price is younger than the asset's `maxAge`
    /// @return price 1e18 cash per whole unit; zero when it cannot be read
    function oracle(AssetConfig storage c) internal view returns (bool fresh, uint256 price) {
        try ORACLE.oraclePricePairState(c.oracleType, c.feedId, "USD") returns (
            IOracleModule.PricePairState memory st
        ) {
            if (st.pairPrice == 0 || st.baseTimestamp == 0) return (false, 0);
            return (block.timestamp <= uint256(st.baseTimestamp) + c.maxAge, st.pairPrice);
        } catch {
            return (false, 0);
        }
    }

    /// @dev The price for valuation: a stale one is acceptable, a missing one is not.
    function markPrice(AssetConfig storage c) internal view returns (uint256 price) {
        price = ORACLE.oraclePricePairState(c.oracleType, c.feedId, "USD").pairPrice;
        if (price == 0) revert OracleMissing();
    }

    /// @notice What the vault holds of `currency`: the token itself plus its vault claims.
    function holding(BasketContext memory ctx, Currency currency) internal view returns (uint256) {
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this)) + ctx.vault.balanceOf(address(this), currency);
    }

    /// @notice The vault's default exchange subaccount, which trades off its bank balance.
    function subaccount() internal view returns (string memory) {
        return SubaccountLib.defaultSubaccount(address(this));
    }

    /// @dev Make sure `amount` of `currency` is held as the token, pulling the shortfall out of claims.
    function ensureToken(BasketContext memory ctx, Currency currency, uint256 amount) internal {
        uint256 bal = IERC20(Currency.unwrap(currency)).balanceOf(address(this));
        if (bal < amount) lock(ctx, OP_FROM_CLAIMS, currency, amount - bal);
    }

    function lock(BasketContext memory ctx, uint8 op, Currency currency, uint256 amount) internal {
        setLockOpen(true);
        ctx.vault.lock(abi.encode(op, currency, amount));
        setLockOpen(false);
    }

    function find(IExchangeDerivatives.DerivativePosition[] memory positions, string storage marketId)
        internal
        pure
        returns (bool, IExchangeDerivatives.DerivativePosition memory p)
    {
        bytes32 h = keccak256(bytes(marketId));
        for (uint256 k; k < positions.length; ++k) {
            if (keccak256(bytes(positions[k].marketID)) == h) return (true, positions[k]);
        }
        return (false, p);
    }

    /// @dev Margin plus unrealised PnL at `price`, in cash units, floored at zero.
    function positionValue(BasketContext memory ctx, IExchangeDerivatives.DerivativePosition memory p, uint256 price)
        internal
        pure
        returns (uint256)
    {
        int256 move = p.isLong ? price.toInt256() - p.entryPrice.toInt256() : p.entryPrice.toInt256() - price.toInt256();
        int256 value = p.margin.toInt256() + move * p.quantity.toInt256() / 1e18;
        // forge-lint: disable-next-line(unsafe-typecast) - positive by the test.
        return value <= 0 ? 0 : fromApi(ctx, uint256(value), Math.Rounding.Floor);
    }

    /// @dev An amount of an asset at `price`, in cash units.
    function assetToCash(BasketContext memory ctx, uint256 amount, uint256 price, uint8 decimals, Math.Rounding r)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(amount, price, 10 ** (uint256(decimals) + 18 - ctx.cashDecimals), r);
    }

    /// @dev 1e18 whole units (the exchange's quantity format) at `price`, in cash units.
    function unitsToCash(BasketContext memory ctx, uint256 units, uint256 price) internal pure returns (uint256) {
        return fromApi(ctx, Math.mulDiv(units, price, 1e18), Math.Rounding.Floor);
    }

    /// @dev A token amount in 1e18 whole units.
    function toUnits(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        return decimals == 18 ? amount : Math.mulDiv(amount, 1e18, 10 ** uint256(decimals));
    }

    /// @dev The exchange's 18-decimal format to cash units.
    function fromApi(BasketContext memory ctx, uint256 value, Math.Rounding r) internal pure returns (uint256) {
        return Math.mulDiv(value, 1, 10 ** (18 - uint256(ctx.cashDecimals)), r);
    }

    function setLockOpen(bool open) internal {
        assembly ("memory-safe") {
            tstore(LOCK_OPEN_SLOT, open)
        }
    }

    function lockOpen() internal view returns (bool open) {
        assembly ("memory-safe") {
            open := tload(LOCK_OPEN_SLOT)
        }
    }
}
