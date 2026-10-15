// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IExchangeDerivatives} from "../src/interfaces/IExchangeDerivatives.sol";
import {StockAdmin} from "../src/stock/StockAdmin.sol";
import {StockHedge} from "../src/stock/StockHedge.sol";
import {StockPricing} from "../src/stock/StockPricing.sol";
import {StockRestock} from "../src/stock/StockRestock.sol";
import {Refusal, StockConfig} from "../src/stock/StockTypes.sol";
import {LazerBuilder} from "./utils/LazerBuilder.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// The 10-15 review's High findings, each first proven against the unfixed code (the attack went
/// through) and kept here as the regression test that it no longer does.
contract StockReviewFixesTest is StockVaultHarness {
    address internal constant ATTACKER = address(0xA77A);

    // ── the owner cannot redirect restocking to itself ────────────────────

    function test_theIssuerIsTheRegistrysOnly() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockAdmin.NotRegistryIssuer.selector, ATTACKER));
        x.setRoles(ATTACKER, GUARDIAN, ATTACKER);
        vm.prank(OWNER);
        x.setRoles(KEEPER, GUARDIAN, address(0)); // none stops memo restocking
        vm.prank(OWNER);
        x.setRestockMemo('{"did_id":"\x04",\x01\x02\x03}');
        vm.prank(KEEPER);
        vm.expectRevert(StockRestock.RestockUnavailable.selector);
        x.restock(false, 1_000e6, 3.3 ether, 1);
    }

    function test_theTemplateCannotNameAnotherPayeeOrExpiry() public {
        vm.startPrank(OWNER);
        vm.expectRevert(StockRestock.BadMemo.selector);
        x.setRestockMemo("\x01\x02\x03\x04"); // the vault, but not as did_id
        vm.expectRevert(StockRestock.BadMemo.selector);
        x.setRestockMemo('{"did_id":"0xa77a","did_id":"\x04",\x01\x02\x03}'); // a second payee
        vm.expectRevert(StockRestock.BadMemo.selector);
        x.setRestockMemo('{"did_id":"\x04","expiry_days":9,\x01\x02\x03}'); // its own expiry
        x.setRestockMemo('{"did_id":"\x04",\x01\x02\x03}');
        vm.stopPrank();
    }

    function test_theMemoPaysTheVaultInTheConfiguredUnit() public {
        StockConfig memory c = _cfg();
        c.restockExpiryUnit = 1 hours;
        _setCfg(c);
        vm.prank(OWNER);
        x.setRestockMemo('{"did_id":"\x04","offer":"\x01","request":"\x02",\x03}');
        bytes memory memo = abi.encodePacked(
            '{"did_id":"',
            vm.toLowercase(vm.toString(address(sv))),
            '","offer":"1000000000","request":"3300000000000000000","expiry_hours":2}'
        );
        vm.expectCall(address(cash), abi.encodePacked(abi.encodeCall(IERC20.transfer, (ISSUER, 1_000e6)), memo));
        vm.prank(KEEPER);
        x.restock(false, 1_000e6, 3.3 ether, 2);
    }

    // ── a halt always has a way out ───────────────────────────────────────

    function test_aHaltAcrossABigMoveIsAcceptedAtAStatedPrice() public {
        x.poke(); // anchored at 300
        vm.prank(GUARDIAN);
        x.haltAction();
        _price(MANTISSA * 14 / 10); // reopens 40% higher
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockPricing.ActionMove.selector, 420e18, PRICE));
        x.acceptAction(1e12, 3000);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockPricing.ActionMove.selector, 420e18, 400e18));
        x.acceptActionAt(1e12, 100, 400e18); // the owner's expectation is still checked
        vm.prank(OWNER);
        x.acceptActionAt(1e12, 100, 420e18);
        assertFalse(x.actionPending());
        assertEq(x.state().anchorPrice, 420e18);
    }

    // ── a split in the feed first halts instead of re-anchoring ───────────

    function test_aSplitSizedJumpHaltsInsteadOfReanchoring() public {
        x.poke();
        _price(MANTISSA / 4);
        x.poke(); // 75% move: halted at once, no reanchorDelay to wait out
        assertTrue(x.actionPending());
        assertEq(x.state().anchorPrice, PRICE);
        assertEq(uint256(sv.quoteFill(true, 300e6, true, "").reason), uint256(Refusal.Action));
    }

    function test_aBreakerSizedJumpStillReanchorsAfterTheDelay() public {
        x.poke();
        _price(MANTISSA * 12 / 10); // +20%: past the 15% breaker, under the 30% action bound
        x.poke();
        vm.warp(block.timestamp + 301);
        _price(MANTISSA * 12 / 10);
        x.poke();
        assertFalse(x.actionPending());
        assertEq(x.state().anchorPrice, 360e18);
    }

    // ── a signed update must carry what protects the vault ────────────────

    function test_anUpdateWithoutAnExponentIsNeverStored() public {
        x.poke();
        uint64 ts = uint64(block.timestamp) * 1e6 + ++nonce;
        bytes memory p = abi.encodePacked(
            LazerBuilder.PAYLOAD_MAGIC, ts, LazerBuilder.FIXED_RATE_200, uint8(1), FEED, uint8(2), uint8(0), MANTISSA
        );
        p = abi.encodePacked(p, uint8(12), uint8(1), ts);
        assertEq(store.update(LazerBuilder.sign(SIGNER_KEY, p)), 0);
        assertEq(x.state().anchorPrice, PRICE);
    }

    // ── the margin top-up counts the short's loss ─────────────────────────

    function _equity() internal view returns (uint256 margin, int256 equity, uint256 target) {
        IExchangeDerivatives.DerivativePosition memory p = exchange.subaccountPositions(_sub())[0];
        uint256 mark = 345e18;
        margin = p.margin;
        equity = int256(p.margin) + (int256(p.entryPrice) - int256(mark)) * int256(p.quantity) / 1e18;
        target = Math.mulDiv(p.quantity, mark, 1e18) * 10 / 30;
    }

    function test_anyoneTopsUpAShortWhoseEquityIsLow() public {
        _hedge(PRICE);
        _price(MANTISSA * 115 / 100); // +15% at 3x: margin untouched, equity about half the target
        (uint256 before,,) = _equity();
        x.topUpMargin();
        (uint256 margin, int256 equity, uint256 target) = _equity();
        assertGt(margin, before);
        assertEq(uint256(equity), target, "equity back at the target leverage");
    }

    function test_theKeeperTopsUpBelowTheTargetAnyoneOnlyBelow70Percent() public {
        _hedge(PRICE);
        _price(MANTISSA * 103 / 100); // +3%: equity under the target, above 70% of it
        vm.expectRevert(StockHedge.MarginHealthy.selector);
        x.topUpMargin();
        vm.prank(KEEPER);
        x.topUpMargin();
    }
}
