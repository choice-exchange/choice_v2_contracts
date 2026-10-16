// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {RfqSettlement} from "./RfqSettlement.sol";

/// @title RfqPoolArb
/// @notice Closes the gap between a CL pool and an `RfqSettlement` quote in ONE transaction:
/// buy where it is cheap, sell where it is dear, and revert unless the currency the trade
/// started in comes back ahead by at least `minProfit`.
///
/// This is what keeps a pool in an issued asset priced at the issuer's mark. When the pool
/// trades below the issuer's bid, `PoolThenQuote` buys the asset from the pool and sells it to
/// the issuer; when it trades above the issuer's offer, `QuoteThenPool` buys from the issuer and
/// sells into the pool. Because both legs settle in the same transaction there is no window in
/// which one leg has filled and the other has not, and so no inventory to hedge.
///
/// **The profit check is the only guard, by design.** The pool swap runs to the extreme price
/// bound, as `ChoiceRouter` does, and the quote is filled exactly as signed. What the owner
/// asks for is measured on the realised balance of the starting currency, which a per-leg
/// minimum cannot game.
///
/// Owner-operated: it trades its own balance, and the owner deposits and withdraws by plain
/// transfer and `withdraw`. Single-vault: the vault is fixed at construction.
contract RfqPoolArb is Ownable2Step, ReentrancyGuardTransient, ILockCallback {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    enum Order {
        /// Swap `poolAmountIn` on the pool, then sell the proceeds to the quote.
        PoolThenQuote,
        /// Fill the quote, then sell what it paid out into the pool.
        QuoteThenPool
    }

    /// @param key the pool; `key.poolManager` must belong to `VAULT`
    /// @param zeroForOne the POOL leg's direction
    /// @param poolAmountIn `PoolThenQuote` only: the pool leg's exact input. `QuoteThenPool`
    /// sells exactly `quote.amountOut`, so it ignores this.
    /// @param minProfit the starting currency's required net gain, in its smallest unit
    struct Arb {
        PoolKey key;
        bool zeroForOne;
        uint256 poolAmountIn;
        Order order;
        RfqSettlement settlement;
        RfqSettlement.Quote quote;
        bytes signature;
        uint256 minProfit;
    }

    IVault public immutable VAULT;

    event Arbed(Order order, Currency indexed currency, uint256 profit);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error NotVault();
    error LegsDoNotConnect();
    error ShortPoolLeg(uint256 got, uint256 needed);
    error NotProfitable(uint256 before, uint256 afterwards, uint256 minProfit);

    constructor(address owner_, IVault vault) Ownable(owner_) {
        VAULT = vault;
    }

    /// @return profit the starting currency's net gain
    function run(Arb calldata a) external onlyOwner nonReentrant returns (uint256 profit) {
        Currency poolIn = a.zeroForOne ? a.key.currency0 : a.key.currency1;
        Currency poolOut = a.zeroForOne ? a.key.currency1 : a.key.currency0;
        RfqSettlement.Quote calldata q = a.quote;

        // The two legs must form a loop: whatever the first leg pays out is what the second
        // leg spends, and the second leg pays out in the currency the first one spent.
        Currency start;
        if (a.order == Order.PoolThenQuote) {
            if (q.tokenIn != Currency.unwrap(poolOut) || q.tokenOut != Currency.unwrap(poolIn)) {
                revert LegsDoNotConnect();
            }
            start = poolIn;
        } else {
            if (q.tokenOut != Currency.unwrap(poolIn) || q.tokenIn != Currency.unwrap(poolOut)) {
                revert LegsDoNotConnect();
            }
            start = poolOut;
        }

        uint256 before = start.balanceOfSelf();

        if (a.order == Order.PoolThenQuote) {
            uint256 got = _swap(a.key, a.zeroForOne, a.poolAmountIn);
            if (got < q.amountIn) revert ShortPoolLeg(got, q.amountIn);
            _fill(a);
        } else {
            _fill(a);
            _swap(a.key, a.zeroForOne, q.amountOut);
        }

        uint256 afterwards = start.balanceOfSelf();
        if (afterwards < before + a.minProfit) revert NotProfitable(before, afterwards, a.minProfit);
        profit = afterwards - before;
        emit Arbed(a.order, start, profit);
    }

    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    /// @inheritdoc ILockCallback
    /// @dev Only `VAULT` can call this, and the vault only calls back the contract that took
    /// its lock - which happens solely inside `run`, for the owner. So the payload is ours.
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(VAULT)) revert NotVault();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));

        ICLPoolManager(address(key.poolManager))
            .swap(
                key,
                ICLPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    // Negative amountSpecified is exact-input.
                    amountSpecified: -amountIn.toInt256(),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
                }),
                ""
            );

        // Debt first, then credit: the vault pays a credit out of real reserves.
        Currency inCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outCurrency = zeroForOne ? key.currency1 : key.currency0;
        int256 owed = VAULT.currencyDelta(address(this), inCurrency);
        if (owed < 0) {
            VAULT.sync(inCurrency);
            // forge-lint: disable-next-line(unsafe-typecast) - magnitude of a known negative.
            IERC20(Currency.unwrap(inCurrency)).safeTransfer(address(VAULT), uint256(-owed));
            VAULT.settle();
        }
        int256 credit = VAULT.currencyDelta(address(this), outCurrency);
        // forge-lint: disable-next-line(unsafe-typecast) - guarded positive.
        if (credit > 0) VAULT.take(outCurrency, address(this), uint256(credit));
        return "";
    }

    // ── internals ─────────────────────────────────────────────────────────

    function _swap(PoolKey calldata key, bool zeroForOne, uint256 amountIn) private returns (uint256 got) {
        Currency outCurrency = zeroForOne ? key.currency1 : key.currency0;
        uint256 before = outCurrency.balanceOfSelf();
        VAULT.lock(abi.encode(key, zeroForOne, amountIn));
        got = outCurrency.balanceOfSelf() - before;
    }

    function _fill(Arb calldata a) private {
        IERC20(a.quote.tokenIn).forceApprove(address(a.settlement), a.quote.amountIn);
        a.settlement.fill(a.quote, a.signature, address(this));
    }
}
