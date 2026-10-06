// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

import {IBurnSink} from "./IBurnSink.sol";
import {IBurnableERC20} from "./IBurnableERC20.sol";

/// @notice `BuybackBurnSink`'s whole external surface: functions, events, errors and the `Route`
/// it returns. Everything outside the sink itself uses this and never imports the sink's source.
/// The ownership functions come from OpenZeppelin's `Ownable2Step`, so they are not repeated here.
///
/// @dev 🔴 Load-bearing since sink 1.8.0. The sink is compiled under its own optimizer profile (see
/// `foundry.toml`) because it does not fit EIP-170 at the repo's 25,666 runs. A compilation
/// restriction reaches every file that imports the restricted one, and everything compiled
/// alongside it. So a file that imported `BuybackBurnSink.sol` would rebuild its own dependency
/// tree at 1,000 runs: the cranker's bytecode, every `type(...).creationCode` a deploy script
/// embeds, and every other contract a test touches, along with the gas that test measures.
/// Import this, and deploy or read the sink through its artifact.
///
/// The sink inherits this interface, so the compiler keeps the two in step.
interface IBuybackBurnSink is IBurnSink, ILockCallback {
    /// @notice A resolved conversion path: one or two exact-input swaps ending in `QUOTE`.
    /// @dev Fixed-size rather than an array, because the sink builds at most two legs and a
    /// bounded shape is one less thing a lock callback can be handed too much of.
    struct Route {
        PoolKey first;
        bool firstZeroForOne;
        PoolKey second;
        bool secondZeroForOne;
        /// @dev 0 = no route, 1 = straight to `QUOTE`, 2 = through a registered quote route.
        uint8 legs;
        /// @dev 1.7.0. The share of the FIRST leg's LP fee that is paid to a launch's creator, in
        /// bps: read off the locked position when that leg is a launch's own graduation pool,
        /// and 10000 (assume all of it) otherwise. It feeds the sandwich bound in `_legFees`,
        /// because a creator gets that share of their own LP fee back.
        uint16 firstLpCreatorBps;
    }

    error ZeroAddress();
    error InvalidBps(uint16 bps);
    error BurnBpsBelowFloor(uint16 given, uint16 floor);
    error PoolMissingLeg();
    error PoolNotInitialised();
    error ImpactBpsTooLow(uint16 given, uint16 floor);
    error RateLimitRequired();
    error NotVault();
    error LockNotOpen();
    error NotSelf();
    error CannotSweepBuybackLeg(Currency currency);
    error NotAConvertibleCurrency(Currency currency);
    error SweepRequiresHold(Currency currency);
    error LaunchDoesNotTrade(uint256 launchId, Currency currency);
    error TooManyLockers(uint256 given, uint256 max);
    error DuplicateLocker(address locker);
    error LockerHasAnotherPositionManager(address locker);
    error RouteMissingLeg(Currency asset);
    error NotOperator(address caller);
    error NoBuybackPool();
    error NothingToBuyBack();
    /// @dev Raised inside the lock when the pool has no liquidity between spot and the limit, so
    /// the leg could not fill at all. It unwinds the lock, and on the permissionless path the
    /// `try` turns that into a park that spends no rate-limit window.
    error NothingFillable();
    error BelowMinimumRate(uint256 spent, uint256 received, uint256 minOutPerInWad);
    /// @dev 1.8.0: an operator buyback must name the least it will accept.
    error MinimumRateRequired();
    /// @dev 1.8.0: the operator shares the public path's window.
    error RateLimited(uint256 opensAt);
    /// @dev 1.8.0: zero is "unset", which is a state, never a setting.
    error TrancheCapRequired();
    error DepthRequired();

    /// @param quoteSpent quote actually consumed; may be less than offered if the limit bound.
    event BoughtBack(uint256 quoteOffered, uint256 quoteSpent, uint256 tokensReceived);
    /// @param burnt destroyed via `BURN_TOKEN.burn`.
    /// @param toTreasury always zero since 1.8.0, which pays the ops share in `QUOTE` and reports
    /// it as `TreasuryPaid`. The field stays so indexers built against 1.7.0 keep decoding.
    event Burnt(uint256 burnt, uint256 toTreasury);
    /// @param accrued what this buyback added to `treasuryOwed`.
    event TreasuryAccrued(uint256 accrued, uint256 owed);
    event TreasuryPaid(address indexed treasury, uint256 amount);
    /// @param quoteReceived what the sink now holds to buy back with; it goes on to do so.
    event Converted(Currency indexed currency, uint256 offered, uint256 spent, uint256 quoteReceived);
    /// @param reason 0 = below the minimum, 1 = inside `minBuybackInterval`, 2 = currency has no
    /// route, 3 = the swap itself reverted, 4 = the burn or the treasury payout reverted, 5 = held
    /// by policy (D32), 6 = a launch token reached `burn`, which carries no launch id to look its
    /// pool up by - `convert(currency, launchId)` is what moves it. Funds stay here in every
    /// case. 7 = the operator is live and the permissionless buyback waits for it (1.7.0).
    /// 8 = no tranche cap has been set, so nothing trades yet (1.8.0).
    event Parked(Currency indexed currency, uint256 amount, uint8 reason);
    event OperatorUpdated(address operator, uint32 publicFallbackDelay);
    event MaxBuybackAmountUpdated(uint256 maxBuybackAmount);
    event BurnBpsUpdated(uint16 oldBps, uint16 newBps);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event BuybackPoolUpdated(PoolKey key, bool quoteIsCurrency0);
    /// @param anchor the locked position every buyback is sized against.
    event BuybackLaunchUpdated(uint256 launchId, uint256 anchor);
    event GuardsUpdated(uint256 minBuybackAmount, uint16 maxImpactBps, uint32 minBuybackInterval);
    event LockersUpdated(address[] lockers);
    /// @param key the pool the asset reaches `QUOTE` through; a zero `poolManager` clears it.
    /// @param depth the liquidity a conversion through it is sized against.
    event QuoteRouteUpdated(Currency indexed asset, PoolKey key, bool assetIsCurrency0, uint128 depth);
    event HoldUpdated(Currency indexed currency, bool held);
    event MinConvertAmountUpdated(Currency indexed currency, uint256 amount);
    event TokenSwept(Currency indexed currency, address indexed to, uint256 amount);

    // Constants and immutables
    function BPS_DENOMINATOR() external view returns (uint16);
    function MIN_IMPACT_BPS() external view returns (uint16);
    function MAX_LOCKERS() external view returns (uint256);
    function BURN_TOKEN() external view returns (IBurnableERC20);
    function QUOTE() external view returns (Currency);
    function VAULT() external view returns (IVault);
    function POSITION_MANAGER() external view returns (ICLPositionManager);
    function MIN_BURN_BPS() external view returns (uint16);

    // State
    function burnBps() external view returns (uint16);
    function treasury() external view returns (address);
    function treasuryOwed() external view returns (uint256);
    function buybackPool()
        external
        view
        returns (
            Currency currency0,
            Currency currency1,
            IHooks hooks,
            IPoolManager poolManager,
            uint24 fee,
            bytes32 parameters
        );
    function quoteIsCurrency0() external view returns (bool);
    function buybackLaunchId() external view returns (uint256);
    function buybackAnchor() external view returns (uint256);
    function buybackLpCreatorBps() external view returns (uint16);
    function minBuybackAmount() external view returns (uint256);
    function maxImpactBps() external view returns (uint16);
    function minBuybackInterval() external view returns (uint32);
    function lastBuybackAt() external view returns (uint64);
    function maxBuybackAmount() external view returns (uint256);
    function operator() external view returns (address);
    function publicFallbackDelay() external view returns (uint32);
    function operatorSince() external view returns (uint64);
    function lastOperatorBuybackAt() external view returns (uint64);
    function isLocker(address locker) external view returns (bool);
    function quoteRouteDepth(Currency asset) external view returns (uint128);
    function isHeld(Currency currency) external view returns (bool);
    function lastConvertAt(Currency currency) external view returns (uint64);
    function minConvertAmount(Currency currency) external view returns (uint256);

    // Moving revenue
    function buyback() external;
    function operatorBuyback(uint256 maxQuoteIn, uint256 minOutPerInWad)
        external
        returns (uint256 spent, uint256 received);
    function convert(Currency currency, uint256 launchId) external;
    function payTreasury() external;
    function settleBurnTokenSelf() external;
    function payTreasurySelf() external;

    // Views
    function pendingQuote() external view returns (uint256);
    function canBuyback() external view returns (bool);
    function publicBuybackOpensAt() external view returns (uint256);
    function previewBuyback()
        external
        view
        returns (
            uint256 offer,
            uint160 sqrtPriceX96,
            uint128 liquidity,
            uint256 swapFeePips,
            uint256 hookFeePips,
            uint256 unrecoverablePips
        );
    function quoteRoute(Currency asset) external view returns (PoolKey memory key, bool assetIsCurrency0, bool found);
    function registeredQuoteRoute(Currency asset)
        external
        view
        returns (PoolKey memory key, bool assetIsCurrency0, bool found);
    function canConvert(Currency currency, uint256 launchId) external view returns (bool);
    function conversionRoute(Currency currency, uint256 launchId) external view returns (Route memory);
    function launchPool(uint256 launchId) external view returns (PoolKey memory key, address locker);
    function lockers() external view returns (address[] memory);

    // Owner
    function setBurnBps(uint16 newBurnBps) external;
    function setTreasury(address newTreasury) external;
    function setBuybackLaunch(uint256 launchId) external;
    function setGuards(uint256 newMinBuybackAmount, uint16 newMaxImpactBps, uint32 newMinBuybackInterval) external;
    function setOperator(address newOperator, uint32 newFallbackDelay) external;
    function setMaxBuybackAmount(uint256 newMaxBuybackAmount) external;
    function setLockers(address[] calldata newLockers) external;
    function setQuoteRoute(Currency asset, PoolKey calldata key, uint128 depth) external;
    function setHold(Currency currency, bool held) external;
    function setMinConvertAmount(Currency currency, uint256 amount) external;
    function sweep(Currency currency, address to) external returns (uint256 amount);
}
