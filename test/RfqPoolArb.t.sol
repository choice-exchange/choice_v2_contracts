// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {RfqSettlement} from "../src/rfq/RfqSettlement.sol";
import {RfqPoolArb} from "../src/rfq/RfqPoolArb.sol";

/// The real `Vault` + `CLPoolManager`, one pool at 1:1, and an issuer quoting around it.
contract RfqPoolArbTest is Test {
    using CLPoolParametersHelper for bytes32;

    address internal constant OWNER = address(0x0A11);
    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;

    uint256 internal signerKey = 0x51611E7;

    Vault internal vault;
    CLPoolManager internal manager;
    RfqSettlement internal rfq;
    RfqPoolArb internal arb;

    MockERC20 internal cash; // what the issuer is paid in
    MockERC20 internal asset; // what the issuer issues
    PoolKey internal key;
    bool internal cashIs0;

    function setUp() public {
        vault = new Vault();
        manager = new CLPoolManager(vault);
        vault.registerApp(address(manager));

        cash = new MockERC20("CASH", "CASH", 18);
        asset = new MockERC20("ASSET", "ASSET", 18);
        cashIs0 = address(cash) < address(asset);
        key = PoolKey({
            currency0: Currency.wrap(cashIs0 ? address(cash) : address(asset)),
            currency1: Currency.wrap(cashIs0 ? address(asset) : address(cash)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(manager)),
            fee: 3000,
            parameters: bytes32(0).setTickSpacing(60)
        });
        _seedPool(100_000 ether);

        rfq = new RfqSettlement(OWNER, vm.addr(signerKey));
        cash.mint(address(rfq), 1_000 ether);
        asset.mint(address(rfq), 1_000 ether);
        vm.startPrank(OWNER);
        rfq.setOutflowCap(address(cash), 1_000 ether);
        rfq.setOutflowCap(address(asset), 1_000 ether);
        vm.stopPrank();

        arb = new RfqPoolArb(OWNER, vault);
        cash.mint(address(arb), 100 ether);
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _seedPool(uint256 amount) internal {
        manager.initialize(key, SQRT_1_1);
        CLPoolManagerRouter seeder = new CLPoolManagerRouter(vault, manager);
        cash.mint(address(this), amount);
        asset.mint(address(this), amount);
        cash.approve(address(seeder), type(uint256).max);
        asset.approve(address(seeder), type(uint256).max);
        seeder.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(amount), salt: bytes32(0)
            }),
            ""
        );
    }

    function _quote(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, uint256 nonce)
        internal
        view
        returns (RfqSettlement.Quote memory q, bytes memory sig)
    {
        q = RfqSettlement.Quote({
            taker: address(arb),
            tokenIn: tokenIn,
            amountIn: amountIn,
            tokenOut: tokenOut,
            amountOut: amountOut,
            nonce: nonce,
            deadline: block.timestamp + 30
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, rfq.quoteDigest(q));
        sig = abi.encodePacked(r, s, v);
    }

    /// The pool leg's direction when it spends cash.
    function _cashToAsset() internal view returns (bool) {
        return cashIs0;
    }

    function _args(
        RfqPoolArb.Order order,
        bool zeroForOne,
        uint256 poolAmountIn,
        RfqSettlement.Quote memory q,
        bytes memory sig,
        uint256 minProfit
    ) internal view returns (RfqPoolArb.Arb memory) {
        return RfqPoolArb.Arb({
            key: key,
            zeroForOne: zeroForOne,
            poolAmountIn: poolAmountIn,
            order: order,
            settlement: rfq,
            quote: q,
            signature: sig,
            minProfit: minProfit
        });
    }

    // ── both directions ───────────────────────────────────────────────────

    /// The pool sells the asset at ~1.00 and the issuer bids 1.02: buy from the pool, sell to
    /// the issuer, keep the difference.
    function test_poolCheapIssuerBidsHigher() public {
        (RfqSettlement.Quote memory q, bytes memory sig) =
            _quote(address(asset), 9.9 ether, address(cash), 10.098 ether, 1);

        vm.prank(OWNER);
        uint256 profit = arb.run(_args(RfqPoolArb.Order.PoolThenQuote, _cashToAsset(), 10 ether, q, sig, 0.09 ether));

        assertEq(profit, 0.098 ether, "profit is quote payout minus pool spend");
        assertEq(cash.balanceOf(address(arb)), 100.098 ether);
        assertGt(asset.balanceOf(address(arb)), 0, "pool overshoot stays with the arb");
        assertEq(asset.balanceOf(address(rfq)), 1_000 ether + 9.9 ether, "issuer got the asset");
        assertTrue(rfq.isNonceUsed(1));
    }

    /// The pool buys the asset at ~1.00 and the issuer offers it at 0.98: buy from the issuer,
    /// sell into the pool.
    function test_poolRichIssuerOffersLower() public {
        (RfqSettlement.Quote memory q, bytes memory sig) = _quote(address(cash), 9.8 ether, address(asset), 10 ether, 2);

        uint256 before = cash.balanceOf(address(arb));
        vm.prank(OWNER);
        uint256 profit = arb.run(_args(RfqPoolArb.Order.QuoteThenPool, !_cashToAsset(), 0, q, sig, 0.1 ether));

        assertEq(cash.balanceOf(address(arb)), before + profit);
        assertGt(profit, 0.1 ether);
        assertEq(asset.balanceOf(address(arb)), 0, "every asset the issuer paid went into the pool");
        assertEq(cash.balanceOf(address(rfq)), 1_000 ether + 9.8 ether);
    }

    // ── it never trades at a loss ─────────────────────────────────────────

    /// The issuer bids exactly the pool's mid, so the pool's fee makes the loop a loss: the
    /// whole thing reverts and the quote is still unfilled.
    function test_anUnprofitableLoopRevertsAndLeavesTheQuoteUnused() public {
        (RfqSettlement.Quote memory q, bytes memory sig) =
            _quote(address(asset), 9.9 ether, address(cash), 9.9 ether, 3);

        vm.prank(OWNER);
        vm.expectRevert();
        arb.run(_args(RfqPoolArb.Order.PoolThenQuote, _cashToAsset(), 10 ether, q, sig, 0));

        assertFalse(rfq.isNonceUsed(3));
        assertEq(cash.balanceOf(address(arb)), 100 ether);
    }

    function test_minProfitIsEnforced() public {
        (RfqSettlement.Quote memory q, bytes memory sig) =
            _quote(address(asset), 9.9 ether, address(cash), 10.098 ether, 4);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RfqPoolArb.NotProfitable.selector, 100 ether, 100.098 ether, 0.1 ether));
        arb.run(_args(RfqPoolArb.Order.PoolThenQuote, _cashToAsset(), 10 ether, q, sig, 0.1 ether));
    }

    function test_aPoolLegShortOfTheQuoteReverts() public {
        // 10 cash buys ~9.96 asset at 1:1 less 0.3%; the quote wants 10.
        (RfqSettlement.Quote memory q, bytes memory sig) = _quote(address(asset), 10 ether, address(cash), 11 ether, 5);
        vm.prank(OWNER);
        vm.expectPartialRevert(RfqPoolArb.ShortPoolLeg.selector);
        arb.run(_args(RfqPoolArb.Order.PoolThenQuote, _cashToAsset(), 10 ether, q, sig, 0));
    }

    function test_legsThatDoNotFormALoopAreRefused() public {
        // PoolThenQuote spends cash on the pool, so the quote must take asset and pay cash.
        (RfqSettlement.Quote memory q, bytes memory sig) = _quote(address(cash), 1 ether, address(asset), 1 ether, 6);
        vm.prank(OWNER);
        vm.expectRevert(RfqPoolArb.LegsDoNotConnect.selector);
        arb.run(_args(RfqPoolArb.Order.PoolThenQuote, _cashToAsset(), 1 ether, q, sig, 0));

        vm.prank(OWNER);
        vm.expectRevert(RfqPoolArb.LegsDoNotConnect.selector);
        arb.run(_args(RfqPoolArb.Order.QuoteThenPool, _cashToAsset(), 0, q, sig, 0));
    }

    // ── access ────────────────────────────────────────────────────────────

    function test_onlyTheOwnerRuns() public {
        (RfqSettlement.Quote memory q, bytes memory sig) =
            _quote(address(asset), 9.9 ether, address(cash), 10.098 ether, 7);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        arb.run(_args(RfqPoolArb.Order.PoolThenQuote, _cashToAsset(), 10 ether, q, sig, 0));
    }

    function test_theCallbackOnlyAnswersTheVault() public {
        vm.expectRevert(RfqPoolArb.NotVault.selector);
        arb.lockAcquired(abi.encode(key, true, uint256(1)));
    }

    function test_ownerWithdraws() public {
        vm.prank(OWNER);
        arb.withdraw(address(cash), OWNER, 100 ether);
        assertEq(cash.balanceOf(OWNER), 100 ether);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        arb.withdraw(address(cash), address(this), 1);
    }
}
