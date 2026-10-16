// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {StockHedge} from "../src/stock/StockHedge.sol";
import {StockLib} from "../src/stock/StockLib.sol";
import {StockModule} from "../src/stock/StockModule.sol";
import {StockPricing} from "../src/stock/StockPricing.sol";
import {StockRatios} from "../src/stock/StockRatios.sol";
import {Fill, Refusal, StockState} from "../src/stock/StockTypes.sol";
import {MockStockExchange} from "./mocks/StockMocks.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// Corporate actions: prices per token at the vault's tokens-per-share ratio, the halt a ratio change
/// (or a person) sets and only the owner ends, the anchor moving with the accepted ratio, the hedge in
/// shares, and the move to a new perp market after the old one is settled ahead of a split.
contract StockActionTest is StockVaultHarness {
    uint56 internal constant QUARTER = 0.25e12; // after a 4:1 split, one token is four shares
    string internal constant NEW_MARKET = "0x00000000000000000000000000000000000000000000000000000000000000bb";

    function setUp() public override {
        super.setUp();
        x.poke(); // an anchor to check accepted moves against, as any vault that has traded has
    }

    function _announce(uint256 ratio) internal {
        vm.prank(UPDATER);
        ratios.setRatio(address(stock), ratio);
    }

    function _accept(uint56 ratio) internal {
        vm.prank(OWNER);
        x.acceptAction(ratio, 100);
    }

    // ── the halt ──────────────────────────────────────────────────────────

    function test_anAnnouncedRatioRefusesEveryPrice() public {
        vm.prank(OWNER);
        x.setRestockMemo('"did_id":"\x04"\x01\x02\x03');
        _announce(QUARTER);
        assertTrue(x.actionPending());

        assertEq(uint256(sv.quoteFill(true, 300e6, true, "").reason), uint256(Refusal.Action));
        _expectRefusal(Refusal.Action);
        _swap(true, true, 300e6);
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Action));
        x.poke();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Action));
        sv.deposit(1e6, OWNER);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Action));
        sv.withdraw(1e6, OWNER, OWNER);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Action));
        x.restock(false, 1_000e6, 3.3 ether, 1);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Action));
        x.syncHedge();
        x.confirmHedge(); // reading the short back still runs
    }

    function test_aHandHaltIsGuardianKeeperOrOwner() public {
        vm.expectRevert(StockModule.NotPauser.selector);
        x.haltAction();
        vm.prank(GUARDIAN);
        x.haltAction();
        assertTrue(x.actionPending());
        assertEq(uint256(sv.quoteFill(true, 300e6, true, "").reason), uint256(Refusal.Action));
    }

    /// The gap the halt closes: without it, a split is a jump the breaker re-anchors through once it has
    /// stood `reanchorDelay`, and the tokens then sell at a quarter of their value.
    function test_pokeCannotReanchorThroughAHalt() public {
        x.poke(); // anchored at 300
        vm.prank(KEEPER);
        x.haltAction();
        _price(MANTISSA / 4); // the split lands in the feed first
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Action));
        x.poke();
        vm.warp(block.timestamp + 301);
        _price(MANTISSA / 4);
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Action));
        x.poke();
        assertEq(x.state().anchorPrice, PRICE);
    }

    function test_withdrawingAnAnnouncementLeavesAStandingHaltOnceSynced() public {
        _announce(QUARTER);
        x.syncRatio(); // anyone
        _announce(1e12); // withdrawn
        assertTrue(x.actionPending(), "the vault stays halted for the owner to look");
        _accept(1e12);
        assertFalse(x.actionPending());
    }

    // ── accepting ─────────────────────────────────────────────────────────

    function test_acceptingASplitKeepsThePricePerTokenAndTheValue() public {
        x.poke();
        uint256 nav = sv.totalAssets();
        _announce(QUARTER);
        _price(MANTISSA / 4); // 75.00 a share
        _accept(QUARTER);

        assertEq(x.context().tokenPerShare, QUARTER);
        assertEq(x.state().anchorPrice, PRICE, "anchored at the new ratio in the same call");
        assertEq(sv.totalAssets(), nav, "30 tokens are still worth 9,000");
        Fill memory f = sv.quoteFill(true, 300e6, true, "");
        assertEq(uint256(f.reason), uint256(Refusal.None));
        assertEq(f.price, PRICE);
        assertEq(f.spreadBps, 25 + 30, "the re-anchor widen applies");
        _swap(true, true, 300e6);
    }

    function test_acceptMustBeTheAnnouncedRatioAndInRange() public {
        vm.prank(OWNER);
        vm.expectRevert(StockPricing.NoActionPending.selector);
        x.acceptAction(1e12, 100);

        _announce(QUARTER);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockPricing.BadRatio.selector, 0.5e12, QUARTER));
        x.acceptAction(0.5e12, 100);
        vm.prank(KEEPER);
        vm.expectRevert(StockModule.NotOwner.selector);
        x.acceptAction(QUARTER, 100);

        vm.expectRevert(abi.encodeWithSelector(StockRatios.BadRatio.selector, 1e5));
        vm.prank(UPDATER);
        ratios.setRatio(address(stock), 1e5);
        vm.prank(address(0xBAD));
        vm.expectRevert(StockRatios.NotUpdater.selector);
        ratios.setRatio(address(stock), 1e12);
    }

    function test_aHandHaltIsAcceptedAtTheSameRatio() public {
        vm.prank(GUARDIAN);
        x.haltAction();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockPricing.BadRatio.selector, QUARTER, 1e12));
        x.acceptAction(QUARTER, 100);
        _accept(1e12);
        assertEq(uint256(sv.quoteFill(true, 300e6, true, "").reason), uint256(Refusal.None));
    }

    /// The mistake the move bound catches: the ratio accepted while the feed still shows the old price.
    function test_aRatioAcceptedBeforeTheFeedMovesIsRefused() public {
        x.poke();
        _announce(QUARTER);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockPricing.ActionMove.selector, 1_200e18, PRICE));
        x.acceptAction(QUARTER, 3000);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockPricing.ActionMove.selector, 1_200e18, PRICE));
        x.acceptAction(QUARTER, 3001); // over the hard limit, whatever the move
        _price(MANTISSA / 4 * 102 / 100); // the feed has split, and the stock is up 2% since
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockPricing.ActionMove.selector, 306e18, PRICE));
        x.acceptAction(QUARTER, 100);
        vm.prank(OWNER);
        x.acceptAction(QUARTER, 200);
        assertEq(x.state().anchorPrice, 306e18);
    }

    // ── the hedge across a split ──────────────────────────────────────────

    /// What Helix did for a 10:1 split: settle the perp at the oracle before it, launch a new market.
    function test_aSplitThroughASettledMarketKeepsTheVaultWholeAndRehedgesInShares() public {
        _hedge(PRICE);
        assertEq(x.state().shortConfirmed, 30e18, "30 tokens, 30 shares");
        uint256 nav = sv.totalAssets();

        _announce(QUARTER);
        exchange.forceSettle(_sub(), MARKET, PRICE, address(sv));
        x.confirmHedge();
        assertEq(x.state().shortConfirmed, 0);
        assertTrue(x.state().positionLost, "gone with no cover of the vault's");
        assertApproxEqAbs(sv.totalAssets(), nav, 1, "the settlement paid the margin back");

        vm.startPrank(OWNER);
        vm.expectRevert(StockHedge.HedgeOpen.selector);
        x.migrateMarket(NEW_MARKET, 1e15, 1e16); // not before the owner has looked
        x.acceptNav(); // settled, paid back: not merely paused
        x.migrateMarket(NEW_MARKET, 1e15, 1e16);
        _price(MANTISSA / 4);
        x.acceptAction(QUARTER, 100);
        vm.stopPrank();
        assertEq(x.state().marketId, NEW_MARKET);
        assertApproxEqAbs(sv.totalAssets(), nav, 1);

        assertEq(sv.hedgeGap(), 120e18, "30 tokens are 120 shares now");
        vm.prank(KEEPER);
        assertTrue(x.syncHedge());
        MockStockExchange.Order memory o = exchange.pending(0);
        assertEq(o.quantity, 120e18);
        assertEq(o.marketID, NEW_MARKET);
        assertEq(o.worstPrice, 74.55e18, "the worst price is per share: 75 less 60bp");
        vm.roll(block.number + 1);
        exchange.endBlock(75e18);
        x.confirmHedge();
        assertEq(sv.hedgeGap(), 0);
        assertApproxEqAbs(sv.totalAssets(), nav, 2);
    }

    function test_migrationNeedsAHaltAndNothingOpen() public {
        vm.prank(OWNER);
        vm.expectRevert(StockHedge.NoActionPending.selector);
        x.migrateMarket(NEW_MARKET, 1e15, 1e16);

        _hedge(PRICE);
        vm.prank(GUARDIAN);
        x.haltAction();
        vm.prank(OWNER);
        vm.expectRevert(StockHedge.HedgeOpen.selector);
        x.migrateMarket(NEW_MARKET, 1e15, 1e16);
    }

    // ── any ratio ─────────────────────────────────────────────────────────

    /// A split or a reverse split of any size moves the feed and the ratio together and leaves the
    /// price per token and the vault's value where they were (to the feed's own rounding).
    function testFuzz_anyRatioKeepsThePricePerToken(uint256 ratio) public {
        ratio = bound(ratio, 1e9, 1e15);
        if (ratio == 1e12) ratio = 2e12; // no change is no action
        uint256 nav = sv.totalAssets();
        _announce(ratio);
        _price(int64(uint64(uint256(uint64(MANTISSA)) * ratio / 1e12)));
        // The feed moved with the ratio, so the price per token has not moved: a zero bound passes, and
        // it is under half of any ratio's own move, however small the change.
        vm.prank(OWNER);
        x.acceptAction(uint56(ratio), 0);
        assertApproxEqRel(sv.quoteFill(true, 300e6, true, "").price, PRICE, 4e13);
        assertApproxEqRel(sv.totalAssets(), nav, 4e13);
        assertEq(uint256(sv.quoteFill(true, 300e6, true, "").reason), uint256(Refusal.None));
    }
}
