// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceStore} from "../src/interfaces/IPriceStore.sol";
import {OraclePriceStore} from "../src/stock/OraclePriceStore.sol";
import {PriceStore} from "../src/stock/PriceStore.sol";
import {Fill, Refusal} from "../src/stock/StockTypes.sol";
import {LazerBuilder} from "./utils/LazerBuilder.sol";
import {MockOraclePrecompile} from "./mocks/StockMocks.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// Stock vaults on Injective's own relayed Pyth Pro price (`0x67`), with signed relayed payloads still
/// accepted: the newer of the two, the module's dated back by the relay lag.
contract OraclePriceStoreTest is StockVaultHarness {
    MockOraclePrecompile internal oracle = MockOraclePrecompile(0x0000000000000000000000000000000000000067);

    function _newStore() internal override returns (PriceStore) {
        vm.etch(address(oracle), address(new MockOraclePrecompile()).code);
        return new OraclePriceStore(OWNER, vm.addr(SIGNER_KEY), type(uint64).max, 1000);
    }

    function _os() internal view returns (OraclePriceStore) {
        return OraclePriceStore(address(store));
    }

    /// The module holds `usd` for the feed, landed at `landedAt` (block time, seconds).
    function _module(uint256 usd18, uint256 landedAt) internal {
        oracle.set("7", usd18, uint64(landedAt));
    }

    // ── the store ─────────────────────────────────────────────────────────

    function test_theModulePriceIsDatedBackByTheRelayLag() public {
        _module(342.69672e18, block.timestamp + 5);
        IPriceStore.Price memory p = _os().moduleLatest(FEED);
        assertEq(p.price, 34_269_672_000);
        assertEq(p.exponent, -8);
        assertEq(p.feedTimestampUs, (block.timestamp + 5) * 1e6 - 1e6);
        assertEq(p.timestampUs, (block.timestamp + 5) * 1e6, "the batch time is when it landed");
        assertEq(store.latest(FEED).price, 34_269_672_000, "newer than the stored update");
    }

    function test_aNewerSignedUpdateWins() public {
        _module(301e18, block.timestamp - 3);
        assertEq(store.latest(FEED).price, MANTISSA, "the signed update stored now is newer");
        _module(301e18, block.timestamp + 2);
        assertEq(store.latest(FEED).price, 30_100_000_000);
    }

    function test_aFeedTheModuleLacksFallsBackToTheStore() public view {
        assertEq(_os().moduleLatest(FEED).price, 0);
        assertEq(store.latest(FEED).price, MANTISSA);
        assertEq(store.latest(99).price, 0);
    }

    function test_theRelayLagIsOwnersAndBounded() public {
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, KEEPER));
        _os().setRelayLag(0);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(OraclePriceStore.BadRelayLag.selector, 5001));
        _os().setRelayLag(5001);
        vm.prank(OWNER);
        _os().setRelayLag(2500);
        _module(300e18, block.timestamp + 10);
        assertEq(_os().moduleLatest(FEED).feedTimestampUs, (block.timestamp + 10) * 1e6 - 2.5e6);
    }

    function testFuzz_theMantissaIsThePriceAtEightDecimals(uint256 usd18) public {
        usd18 = bound(usd18, 1e10, 9e28);
        _module(usd18, block.timestamp + 2);
        IPriceStore.Price memory p = store.latest(FEED);
        assertEq(uint256(uint64(p.price)), usd18 / 1e10);
    }

    // ── a vault on it ─────────────────────────────────────────────────────

    function test_aVaultFillsOffTheModuleAlone() public {
        vm.warp(block.timestamp + 30); // the signed update is long stale
        assertEq(uint256(sv.quoteFill(true, 300e6, true, "").reason), uint256(Refusal.Stale));
        _module(PRICE, block.timestamp); // landed this second: 1 s old after the lag
        Fill memory f = sv.quoteFill(true, 300e6, true, "");
        assertEq(uint256(f.reason), uint256(Refusal.None));
        assertEq(f.price, PRICE);
        _swap(true, true, 300e6);
    }

    function test_aModulePriceOlderThanMaxAgeIsRefused() public {
        vm.warp(block.timestamp + 30);
        _module(PRICE, block.timestamp - 1); // 2 s with the lag, over the 1.5 s max age
        assertEq(uint256(sv.quoteFill(true, 300e6, true, "").reason), uint256(Refusal.Stale));
    }

    function test_aRelayedSignedPayloadInHookDataBeatsAnOlderModulePrice() public {
        vm.warp(block.timestamp + 30);
        _module(301e18, block.timestamp - 1);
        bytes memory relayed = _update(_feed(MANTISSA));
        Fill memory f = sv.quoteFill(true, 300e6, true, relayed);
        assertEq(uint256(f.reason), uint256(Refusal.None));
        assertEq(f.price, PRICE);
    }

    /// A signed update the filler hands in replaces the module's price only if its feed moved after the
    /// module's price landed: one published inside the relay lag might be older, and the filler would be
    /// choosing between two prices.
    function test_aSignedUpdateFromInsideTheRelayLagDoesNotReplaceTheModulePrice() public {
        vm.warp(block.timestamp + 30);
        _module(301e18, block.timestamp); // landed this second, dated a second back
        LazerBuilder.Feed memory f = _feed(MANTISSA);
        f.feedTimestampUs = uint64(block.timestamp) * 1e6 - 500_000; // newer than the date, not the landing
        Fill memory q = sv.quoteFill(true, 300e6, true, _update(f));
        assertEq(q.price, 301e18);
        assertEq(sv.quoteFill(true, 300e6, true, _update(_feed(MANTISSA))).price, PRICE);
    }

    function test_weekendModeOnAModulePriceStampedAtTheClose() public {
        vm.warp(SAT + 12 hours);
        _module(PRICE, SAT); // the last landing, at Friday's close
        Fill memory f = sv.quoteFill(true, 300e6, true, "");
        assertEq(uint256(f.reason), uint256(Refusal.None));
        assertTrue(f.closed);
        _module(PRICE, SAT - 400); // an outage before the close, past the tolerance
        assertEq(uint256(sv.quoteFill(true, 300e6, true, "").reason), uint256(Refusal.Stale));
    }
}
