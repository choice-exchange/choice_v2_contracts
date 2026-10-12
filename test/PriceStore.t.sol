// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPriceStore} from "../src/interfaces/IPriceStore.sol";
import {PriceStore} from "../src/stock/PriceStore.sol";
import {PythLazerLib} from "../src/stock/PythLazerLib.sol";
import {LazerFixtures} from "./fixtures/LazerFixtures.sol";
import {LazerBuilder} from "./utils/LazerBuilder.sol";

contract PriceStoreTest is Test {
    address internal constant OWNER = address(0x0A11);
    uint256 internal constant KEY = 0x1A2E5;
    uint64 internal constant T0 = 1_791_789_654_400_000; // 2026-10-12 07:20:54.4Z, in microseconds

    PriceStore internal store;
    PriceStore internal real;

    function setUp() public {
        vm.warp(T0 / 1e6);
        store = new PriceStore(OWNER, vm.addr(KEY), type(uint64).max);
        real = new PriceStore(OWNER, LazerFixtures.PYTH_SIGNER, LazerFixtures.SIGNER_EXPIRY);
    }

    // -------------------------------------------------------------------------------------
    // What Pyth really sends
    // -------------------------------------------------------------------------------------

    function test_realUpdateVerifiesAgainstPythsSigner() public view {
        IPriceStore.Price memory p = real.verify(LazerFixtures.UPDATE_13_FEEDS, 2921);
        assertEq(p.timestampUs, LazerFixtures.UPDATE_13_TIMESTAMP_US);
        assertEq(p.price, 386_144_236);
        assertEq(p.exponent, -8);
        assertEq(p.confidence, 223_986);
        assertEq(p.feedTimestampUs, LazerFixtures.UPDATE_13_TIMESTAMP_US);
        assertEq(p.flags, PythLazerLib.HAS_CONFIDENCE | PythLazerLib.HAS_FEED_TIMESTAMP);
    }

    /// A feed whose market is shut rides the fresh batch with its last close as its own time.
    function test_realUpdateCarriesAShutFeedsOwnTime() public view {
        IPriceStore.Price memory p = real.verify(LazerFixtures.UPDATE_13_FEEDS, 2849);
        assertEq(p.price, 21_439_550);
        assertEq(p.exponent, -5);
        assertEq(p.timestampUs, LazerFixtures.UPDATE_13_TIMESTAMP_US);
        assertEq(p.feedTimestampUs, 1_791_590_399_800_000); // Friday 20:00 EDT, less one tick
    }

    function test_realUpdateStoresEveryFeed() public {
        uint256 gasBefore = gasleft();
        uint256 n = real.update(LazerFixtures.UPDATE_13_FEEDS);
        emit log_named_uint("update gas, 13 feeds", gasBefore - gasleft());
        assertEq(n, 13);
        assertEq(real.latest(3441).price, 12_271_954);
        assertEq(real.update(LazerFixtures.UPDATE_13_FEEDS), 0, "the same update twice stores nothing");
    }

    function test_realUpdateVerifyGas() public {
        uint256 gasBefore = gasleft();
        real.verify(LazerFixtures.UPDATE_13_FEEDS, 3441); // the last feed: the whole payload read
        emit log_named_uint("verify gas, 13 feeds, last one", gasBefore - gasleft());
    }

    function test_realUpdateRefusedByAStoreTrustingAnotherSigner() public {
        vm.expectRevert(abi.encodeWithSelector(PriceStore.UntrustedSigner.selector, LazerFixtures.PYTH_SIGNER));
        store.verify(LazerFixtures.UPDATE_13_FEEDS, 2921);
    }

    function test_tamperedByteChangesTheSigner() public {
        bytes memory u = LazerFixtures.UPDATE_13_FEEDS;
        u[100] = bytes1(uint8(u[100]) ^ 1);
        vm.expectPartialRevert(PriceStore.UntrustedSigner.selector);
        real.verify(u, 2921);
    }

    function test_highSIsRefused() public {
        bytes memory u = LazerFixtures.UPDATE_13_FEEDS;
        // The same signature with s' = n - s and the other recovery id recovers the same signer,
        // which is why OpenZeppelin refuses the upper half.
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        uint256 s;
        assembly {
            s := mload(add(u, 68))
        }
        uint256 flipped = n - s;
        assembly {
            mstore(add(u, 68), flipped)
        }
        u[68] = bytes1(uint8(u[68]) ^ 1);
        vm.expectRevert(abi.encodeWithSelector(PriceStore.UntrustedSigner.selector, address(0)));
        real.verify(u, 2921);
    }

    function test_expiredSignerRefused() public {
        vm.warp(LazerFixtures.SIGNER_EXPIRY);
        vm.expectRevert(abi.encodeWithSelector(PriceStore.UntrustedSigner.selector, LazerFixtures.PYTH_SIGNER));
        real.verify(LazerFixtures.UPDATE_13_FEEDS, 2921);
    }

    function test_feedNotCarried() public {
        vm.expectRevert(abi.encodeWithSelector(PriceStore.FeedNotFound.selector, uint32(1)));
        real.verify(LazerFixtures.UPDATE_13_FEEDS, 1);
    }

    // -------------------------------------------------------------------------------------
    // Built updates: every property Pyth can send
    // -------------------------------------------------------------------------------------

    function test_parsesQuoteSessionAndConfidence() public view {
        LazerBuilder.Feed memory f = LazerBuilder.Feed(7, 33_761_000, -5, 4000, T0 - 200_000, 33_760_000, 33_762_000, 0);
        IPriceStore.Price memory p = store.verify(LazerBuilder.one(KEY, T0, f), 7);
        assertEq(p.price, 33_761_000);
        assertEq(p.bestBid, 33_760_000);
        assertEq(p.bestAsk, 33_762_000);
        assertEq(p.confidence, 4000);
        assertEq(p.marketSession, 0);
        assertEq(p.feedTimestampUs, T0 - 200_000);
        assertEq(
            p.flags,
            PythLazerLib.HAS_QUOTE | PythLazerLib.HAS_CONFIDENCE | PythLazerLib.HAS_SESSION
                | PythLazerLib.HAS_FEED_TIMESTAMP
        );
    }

    function test_missingFeedTimestampMeansTheUpdatesOwn() public view {
        IPriceStore.Price memory p = store.verify(LazerBuilder.one(KEY, T0, LazerBuilder.plain(7, 100, -2, 0)), 7);
        assertEq(p.feedTimestampUs, T0);
        assertEq(p.flags & PythLazerLib.HAS_FEED_TIMESTAMP, 0);
    }

    function test_aFeedTimestampAfterTheUpdateIsClamped() public view {
        IPriceStore.Price memory p =
            store.verify(LazerBuilder.one(KEY, T0, LazerBuilder.plain(7, 100, -2, T0 + 5_000_000)), 7);
        assertEq(p.feedTimestampUs, T0);
    }

    function test_crossedQuoteIsDropped() public view {
        LazerBuilder.Feed memory f = LazerBuilder.Feed(7, 100, -2, 1, 0, 101, 99, -1);
        IPriceStore.Price memory p = store.verify(LazerBuilder.one(KEY, T0, f), 7);
        assertEq(p.bestBid, 0);
        assertEq(p.bestAsk, 0);
        assertEq(p.flags & PythLazerLib.HAS_QUOTE, 0);
    }

    function test_skipsFundingAndEmaProperties() public view {
        // feed 7: price, a set funding rate, an unset funding timestamp, EMA price; then feed 8.
        bytes memory p = abi.encodePacked(PythLazerLib.PAYLOAD_MAGIC, T0, uint8(3), uint8(2));
        p = abi.encodePacked(p, uint32(7), uint8(5), uint8(0), int64(500), uint8(6), uint8(1), int64(-3));
        p = abi.encodePacked(p, uint8(7), uint8(0), uint8(10), int64(499), uint8(4), int16(-2));
        p = abi.encodePacked(p, uint32(8), uint8(2), uint8(0), int64(42), uint8(4), int16(0));
        bytes memory u = LazerBuilder.sign(KEY, p);
        assertEq(store.verify(u, 7).price, 500);
        assertEq(store.verify(u, 8).price, 42);
    }

    function test_unknownPropertyReverts() public {
        bytes memory p = abi.encodePacked(PythLazerLib.PAYLOAD_MAGIC, T0, uint8(3), uint8(1));
        p = abi.encodePacked(p, uint32(7), uint8(1), uint8(13), int64(500));
        vm.expectRevert(abi.encodeWithSelector(PythLazerLib.UnknownProperty.selector, uint8(13)));
        store.verify(LazerBuilder.sign(KEY, p), 7);
    }

    function test_badSessionReverts() public {
        LazerBuilder.Feed memory f = LazerBuilder.Feed(7, 100, -2, 1, 0, 0, 0, 5);
        vm.expectRevert(PythLazerLib.MalformedUpdate.selector);
        store.verify(LazerBuilder.one(KEY, T0, f), 7);
    }

    function test_truncatedReverts() public {
        bytes memory u = LazerBuilder.one(KEY, T0, LazerBuilder.plain(7, 100, -2, 0));
        bytes memory short_ = new bytes(70);
        for (uint256 i; i < 70; ++i) {
            short_[i] = u[i];
        }
        vm.expectRevert(PythLazerLib.MalformedUpdate.selector);
        store.verify(short_, 7);
    }

    function test_wrongMagicReverts() public {
        bytes memory u = LazerBuilder.one(KEY, T0, LazerBuilder.plain(7, 100, -2, 0));
        u[0] = 0x00;
        vm.expectRevert(PythLazerLib.MalformedUpdate.selector);
        store.verify(u, 7);
    }

    // -------------------------------------------------------------------------------------
    // Storing
    // -------------------------------------------------------------------------------------

    function test_storeKeepsTheNewestPerFeed() public {
        store.update(LazerBuilder.one(KEY, T0, LazerBuilder.plain(7, 100, -2, 0)));
        assertEq(store.update(LazerBuilder.one(KEY, T0 - 200_000, LazerBuilder.plain(7, 99, -2, 0))), 0);
        assertEq(store.latest(7).price, 100);
        assertEq(store.update(LazerBuilder.one(KEY, T0 + 200_000, LazerBuilder.plain(7, 101, -2, 0))), 1);
        assertEq(store.latest(7).price, 101);
        assertEq(store.latest(8).timestampUs, 0, "a feed never stored reads as zero");
    }

    function test_missingPriceIsNotStored() public {
        assertEq(store.update(LazerBuilder.one(KEY, T0, LazerBuilder.plain(7, 0, -2, 0))), 0);
    }

    function test_rotateSigner() public {
        uint256 next = 0xBEE5;
        vm.startPrank(OWNER);
        store.setSigner(vm.addr(next), uint64(block.timestamp + 1 days));
        store.setSigner(vm.addr(KEY), 0);
        vm.stopPrank();
        store.verify(LazerBuilder.one(next, T0, LazerBuilder.plain(7, 1, 0, 0)), 7);
        bytes memory old = LazerBuilder.one(KEY, T0, LazerBuilder.plain(7, 1, 0, 0));
        vm.expectRevert(abi.encodeWithSelector(PriceStore.UntrustedSigner.selector, vm.addr(KEY)));
        store.verify(old, 7);
    }

    function test_onlyOwnerSetsSigners() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        store.setSigner(address(1), 1);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PriceStore.UntrustedSigner.selector, address(0)));
        store.setSigner(address(0), 1);
    }

    function testFuzz_roundTrip(uint32 id, int64 price, int16 exponent, uint64 conf, uint64 dt) public view {
        dt = uint64(bound(dt, 1, T0 - 1));
        LazerBuilder.Feed memory f = LazerBuilder.Feed(id, price, exponent, conf, T0 - dt, 0, 0, -1);
        IPriceStore.Price memory p = store.verify(LazerBuilder.one(KEY, T0, f), id);
        assertEq(p.price, price);
        assertEq(p.exponent, exponent);
        assertEq(p.confidence, conf);
        assertEq(p.feedTimestampUs, T0 - dt);
    }
}
