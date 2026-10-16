// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {IStockVaultExtension} from "../src/interfaces/IStockVaultExtension.sol";
import {SubaccountLib} from "../src/libraries/SubaccountLib.sol";
import {StockRatios} from "../src/stock/StockRatios.sol";
import {MockStockExchange} from "./mocks/StockMocks.sol";
import {PriceStore} from "../src/stock/PriceStore.sol";
import {StockVault} from "../src/stock/StockVault.sol";
import {FixingConfig, IssuerQuote, RedeemEpoch, StockState} from "../src/stock/StockTypes.sol";
import {LazerBuilder} from "./utils/LazerBuilder.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// Drives one vault through every lane at a constant price per token: instant swaps both ways, fixing
/// commits, settlements and claims, queued redemptions settled in cash or in kind and claimed, issuer
/// quotes both ways, LIMIT orders both ways (filled at the oracle or refunded), the hedge (filled at
/// the oracle), and splits (the ratio announced, the perp settled at the old share price and moved to a
/// new market, the feed moved, the action accepted), with time moving in steps of up to two minutes.
/// Every call may be refused; what matters is what holds after each one.
contract StockHandler is Test {
    StockVault internal immutable SV;
    IStockVaultExtension internal immutable X;
    PriceStore internal immutable STORE;
    MockERC20 internal immutable CASH;
    MockERC20 internal immutable STOCK;
    CLPoolManagerRouter internal immutable ROUTER;
    uint256 internal immutable SIGNER_KEY;
    uint256 internal immutable QUOTE_KEY;
    address internal immutable KEEPER;
    address internal immutable TRADER;
    address internal immutable OWNER;
    address internal immutable UPDATER;
    address internal immutable ISSUER;
    StockRatios internal immutable RATIOS;
    uint32 internal immutable FEED;
    bool internal immutable CASH_IS_0;

    /// @notice The ratio the vault should be at: every split is accepted in the call that makes it.
    uint256 public ratio = 1e12;
    uint256 internal splits;

    PoolKey internal key;
    address[2] internal actors = [address(0xA1), address(0xA2)];
    uint256[] internal fixingIds;
    uint64 internal nonce;
    uint256 internal quoteNonce;

    uint256 public lastPrice;
    bool public priceFell;
    uint256 public calls;
    /// @notice Successful calls per action, so a run that only ever refused cannot pass unnoticed.
    mapping(bytes32 action => uint256) public done;

    struct Wiring {
        StockVault sv;
        PriceStore store;
        MockERC20 cash;
        MockERC20 stock;
        CLPoolManagerRouter router;
        uint256 signerKey;
        uint256 quoteKey;
        address keeper;
        address trader;
        address owner;
        address updater;
        address issuer;
        StockRatios ratios;
        uint32 feed;
        bool cashIs0;
    }

    constructor(Wiring memory w, PoolKey memory key_) {
        SV = w.sv;
        X = IStockVaultExtension(address(w.sv));
        STORE = w.store;
        CASH = w.cash;
        STOCK = w.stock;
        ROUTER = w.router;
        SIGNER_KEY = w.signerKey;
        QUOTE_KEY = w.quoteKey;
        KEEPER = w.keeper;
        TRADER = w.trader;
        OWNER = w.owner;
        UPDATER = w.updater;
        ISSUER = w.issuer;
        RATIOS = w.ratios;
        FEED = w.feed;
        CASH_IS_0 = w.cashIs0;
        key = key_;
        for (uint256 k; k < 2; ++k) {
            CASH.mint(actors[k], 1_000_000e6);
            STOCK.mint(actors[k], 1_000 ether);
            vm.startPrank(actors[k]);
            CASH.approve(address(SV), type(uint256).max);
            STOCK.approve(address(SV), type(uint256).max);
            vm.stopPrank();
        }
        // Each actor holds a quarter of the shares.
        uint256 quarter = SV.balanceOf(w.owner) / 4;
        vm.startPrank(w.owner);
        assertTrue(SV.transfer(actors[0], quarter));
        assertTrue(SV.transfer(actors[1], quarter));
        vm.stopPrank();
        lastPrice = SV.convertToAssets(1e18);
    }

    // ── actions ───────────────────────────────────────────────────────────

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 120));
        _after();
    }

    function swap(bool cashIn, uint256 amount) external {
        _push();
        amount = cashIn ? bound(amount, 1e6, 2_000e6) : bound(amount, 0.01 ether, 5 ether);
        bool zeroForOne = cashIn == CASH_IS_0;
        vm.prank(TRADER);
        try ROUTER.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast) - bounded above.
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        ) {
            done["swap"]++;
        } catch {}
        _after();
    }

    function commit(uint256 who, bool cashIn, uint256 amount) external {
        _push();
        address a = actors[who % 2];
        amount = cashIn ? bound(amount, 10e6, 3_000e6) : bound(amount, 0.05 ether, 10 ether);
        uint64 boundary = uint64((block.timestamp / 60 + 1) * 60);
        vm.prank(a);
        try X.commitFixing(boundary, cashIn, amount, a) returns (uint256 id) {
            fixingIds.push(id);
            done["commit"]++;
        } catch {}
        _after();
    }

    function settleFixing(uint256 back) external {
        // A batch whose tick has passed: the latest, or one of the few before it.
        uint256 boundary = (block.timestamp / 60 - bound(back, 0, 4)) * 60;
        uint64 tickUs = uint64((boundary * 1000 + 2000) * 1000);
        if (block.timestamp * 1e6 < tickUs) return;
        LazerBuilder.Feed memory f = LazerBuilder.Feed(FEED, _mantissa(), -5, 0, tickUs, 0, 0, -1);
        // forge-lint: disable-next-line(unsafe-typecast) - a 2026 timestamp.
        try X.settleFixing(uint64(boundary), LazerBuilder.one(SIGNER_KEY, tickUs, f)) {
            done["settleFixing"]++;
        } catch {}
        _after();
    }

    function claimFixing(uint256 i) external {
        if (fixingIds.length == 0) return;
        try X.claimFixing(fixingIds[i % fixingIds.length]) {
            done["claimFixing"]++;
        } catch {}
        _after();
    }

    function request(uint256 who, uint256 frac) external {
        _push();
        address a = actors[who % 2];
        uint256 shares = SV.balanceOf(a) * bound(frac, 1, 50) / 100;
        vm.prank(a);
        try X.requestRedeem(shares, a, a) {
            done["request"]++;
        } catch {}
        _after();
    }

    function settleRedeems() external {
        _push();
        try X.settleRedeems() {
            done["settleRedeems"]++;
        } catch {}
        _after();
    }

    function inKind() external {
        _push();
        vm.prank(KEEPER);
        try X.startInKind() {
            done["inKind"]++;
        } catch {}
        try X.finishInKind() {
            done["finishInKind"]++;
        } catch {}
        _after();
    }

    function claimRedeem(uint256 who) external {
        address a = actors[who % 2];
        vm.prank(a);
        try X.claimRedeem(a, a) {
            done["claimRedeem"]++;
        } catch {}
        _after();
    }

    function hedge() external {
        _push();
        vm.prank(KEEPER);
        try X.syncHedge() returns (bool ordered) {
            if (ordered) {
                vm.roll(block.number + 1);
                MockStockExchange(address(0x65)).endBlock(_sharePrice());
                X.confirmHedge();
                done["hedge"]++;
            }
        } catch {}
        _after();
    }

    function quote(bool vaultBuys, uint256 units) external {
        _push();
        uint256 stockAmount = bound(units, 1, 20) * 0.1 ether;
        // At the oracle exactly: 300 a unit.
        uint256 cashAmount = stockAmount * 300 / 1e12;
        IssuerQuote memory q = IssuerQuote({
            vaultBuys: vaultBuys,
            stock: stockAmount,
            cash: cashAmount,
            nonce: ++quoteNonce,
            expiry: uint64(block.timestamp + 60)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(QUOTE_KEY, X.quoteDigest(q));
        vm.prank(KEEPER);
        try X.fillQuote(q, abi.encodePacked(r, s, v)) {
            done["quote"]++;
        } catch {}
        _after();
    }

    /// A LIMIT order at the oracle exactly, left open for `answerOrder`.
    function limitOrder(bool sell, uint256 units) external {
        _push();
        uint256 stockAmount = bound(units, 1, 20) * 0.1 ether;
        uint256 cashAmount = stockAmount * 300 / 1e12;
        vm.prank(KEEPER);
        try X.restock(sell, sell ? stockAmount : cashAmount, sell ? cashAmount : stockAmount, 1) {
            done["order"]++;
        } catch {}
        _after();
    }

    /// The issuer answers the open order and it is closed in the same call: filled (the limit, to the
    /// unit) or refunded (the input back).
    function answerOrder(bool fill) external {
        StockState memory s = X.state();
        if (!s.orderOpen) return;
        if (s.orderSell) {
            if (fill) CASH.mint(address(SV), s.orderCash);
            else STOCK.mint(address(SV), s.orderStock);
        } else {
            if (fill) STOCK.mint(address(SV), s.orderStock);
            else CASH.mint(address(SV), s.orderCash);
        }
        X.settleRestock(); // anyone: the ledgers show what came
        done["answer"]++;
        _after();
    }

    /// A split or a reverse split, the way Helix handled one: the perp settled at the last share price
    /// and relaunched under a new id; the issuer's ratio and the feed move together; the owner accepts.
    function split(uint256 pick) external {
        uint256[4] memory choices = [uint256(0.25e12), 0.5e12, 1e12, 2e12];
        uint256 next = choices[pick % 4];
        if (next == ratio) return;
        vm.roll(block.number + 1);
        vm.prank(UPDATER);
        RATIOS.setRatio(address(STOCK), next);
        string memory sub = SubaccountLib.defaultSubaccount(address(SV));
        MockStockExchange(address(0x65)).forceSettle(sub, X.state().marketId, _sharePrice(), address(SV));
        X.confirmHedge();
        vm.startPrank(OWNER);
        X.migrateMarket(string(abi.encodePacked("market-", vm.toString(++splits))), 1e15, 1e16);
        ratio = next;
        vm.warp(block.timestamp + 1); // the split's price is newer than any stored
        _push();
        // forge-lint: disable-next-line(unsafe-typecast) - one of four ratios.
        X.acceptAction(uint56(next), 0);
        vm.stopPrank();
        done["split"]++;
        _after();
    }

    // ── internals ─────────────────────────────────────────────────────────

    /// 300 a token at the current ratio, as the per-share mantissa (exponent -5).
    function _mantissa() internal view returns (int64) {
        // forge-lint: disable-next-line(unsafe-typecast) - at most 60,000,000.
        return int64(uint64(30_000_000 * ratio / 1e12));
    }

    function _sharePrice() internal view returns (uint256) {
        return 300e18 * ratio / 1e12;
    }

    function _push() internal {
        uint64 ts = uint64(block.timestamp) * 1e6 + ++nonce;
        LazerBuilder.Feed memory f = LazerBuilder.Feed(FEED, _mantissa(), -5, 0, ts, 0, 0, -1);
        try STORE.update(LazerBuilder.one(SIGNER_KEY, ts, f)) {} catch {}
    }

    /// @dev A margin hold burns its cash rounded up and the position counts it rounded down, so a
    /// hedge may cost the vault one unit of cash: one part in 1e9 of the share price here, and no more.
    function _after() internal {
        calls++;
        uint256 p = SV.convertToAssets(1e18);
        if (p < lastPrice - lastPrice / 1e9) priceFell = true;
        lastPrice = p;
    }
}

contract StockInvariantTest is StockVaultHarness {
    uint256 internal constant QUOTE_KEY = 0x9007;
    StockHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.startPrank(OWNER);
        x.setQuoteSigner(vm.addr(QUOTE_KEY));
        x.setRestockMemo('{"did_id":"\x04"\x01\x02\x03}');
        x.setFixingConfig(
            FixingConfig({
                interval: 60,
                delayMs: 5000,
                settleWindow: 300,
                spreadBps: 10,
                sizeBps: 0,
                maxSpreadBps: 100,
                minRequest: 10e6,
                maxSide: 50_000e6,
                maxNet: 20_000e6
            })
        );
        vm.stopPrank();
        cash.mint(ISSUER, 1_000_000e6);
        stock.mint(ISSUER, 1_000 ether);
        vm.startPrank(ISSUER);
        cash.approve(address(sv), type(uint256).max);
        stock.approve(address(sv), type(uint256).max);
        vm.stopPrank();

        handler = new StockHandler(
            StockHandler.Wiring({
                sv: sv,
                store: store,
                cash: cash,
                stock: stock,
                router: router,
                signerKey: SIGNER_KEY,
                quoteKey: QUOTE_KEY,
                keeper: KEEPER,
                trader: TRADER,
                owner: OWNER,
                updater: UPDATER,
                issuer: ISSUER,
                ratios: ratios,
                feed: FEED,
                cashIs0: cashIs0
            }),
            key
        );
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](15);
        actions[0] = StockHandler.warp.selector;
        actions[1] = StockHandler.swap.selector;
        actions[2] = StockHandler.commit.selector;
        actions[3] = StockHandler.settleFixing.selector;
        actions[4] = StockHandler.claimFixing.selector;
        actions[5] = StockHandler.request.selector;
        actions[6] = StockHandler.settleRedeems.selector;
        actions[7] = StockHandler.inKind.selector;
        actions[8] = StockHandler.claimRedeem.selector;
        actions[9] = StockHandler.quote.selector;
        actions[10] = StockHandler.hedge.selector;
        actions[11] = StockHandler.warp.selector; // time moves twice as often as anything else
        actions[12] = StockHandler.limitOrder.selector;
        actions[13] = StockHandler.answerOrder.selector;
        actions[14] = StockHandler.split.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    /// Every action has to land in some runs, or the invariants above hold over nothing.
    function afterInvariant() external view {
        bytes32[14] memory names = [
            // forge-lint: disable-next-line(unsafe-typecast) - a short literal.
            bytes32("swap"),
            "hedge",
            "commit",
            "settleFixing",
            "claimFixing",
            "request",
            "settleRedeems",
            "inKind",
            "finishInKind",
            "claimRedeem",
            "quote",
            "order",
            "answer",
            "split"
        ];
        for (uint256 k; k < names.length; ++k) {
            console.log(string(abi.encodePacked(names[k])), handler.done(names[k]));
        }
    }

    function _held(MockERC20 t) internal view returns (uint256) {
        return t.balanceOf(address(sv)) + IVault(address(vault)).balanceOf(address(sv), Currency.wrap(address(t)));
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 128
    /// forge-config: ci.invariant.depth = 60
    function invariant_whatIsHeldCoversWhatIsOwed() public view {
        StockState memory s = x.state();
        assertEq(_held(cash), s.cashBooked + s.cashOwed, "every unit of cash is booked or owed");
        assertEq(_held(stock), s.stockBooked + s.stockOwed, "every unit of stock is booked or owed");
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 128
    /// forge-config: ci.invariant.depth = 60
    function invariant_onlyTheOpenEpochIsInEscrow() public view {
        (uint64 open,,) = x.redeemQueue(0);
        (,, RedeemEpoch memory e) = x.redeemQueue(open);
        assertEq(sv.balanceOf(address(sv)), e.shares, "settled and in-kind epochs burned their shares");
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 128
    /// forge-config: ci.invariant.depth = 60
    function invariant_theSharePriceNeverFallsAtAConstantOracle() public view {
        assertFalse(handler.priceFell(), "no lane costs those who stay, nor a split");
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 128
    /// forge-config: ci.invariant.depth = 60
    function invariant_everySplitIsAcceptedAtItsRatio() public view {
        assertEq(x.context().tokenPerShare, handler.ratio());
        assertFalse(x.actionPending());
    }
}

