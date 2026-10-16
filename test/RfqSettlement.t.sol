// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {RfqSettlement} from "../src/rfq/RfqSettlement.sol";

/// Skims 1% of every transfer, so `fill` must notice it was underpaid.
contract SkimmingToken is MockERC20 {
    constructor() MockERC20("SKIM", "SKIM", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 skim = amount / 100;
        super.transferFrom(from, address(0xdead), skim);
        return super.transferFrom(from, to, amount - skim);
    }
}

/// A one-key smart account: valid when its owner signed the digest.
contract OneKeyWallet is IERC1271 {
    address public immutable OWNER;

    constructor(address owner_) {
        OWNER = owner_;
    }

    function isValidSignature(bytes32 digest, bytes calldata sig) external view returns (bytes4) {
        return ECDSA.recover(digest, sig) == OWNER ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

contract RfqSettlementTest is Test {
    address internal constant OWNER = address(0x0A11);
    address internal constant TAKER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);

    uint256 internal signerKey = 0x51611E7;
    address internal signer;

    RfqSettlement internal rfq;
    MockERC20 internal usdc;
    MockERC20 internal stock;

    function setUp() public {
        signer = vm.addr(signerKey);
        rfq = new RfqSettlement(OWNER, signer);
        usdc = new MockERC20("USDC", "USDC", 6);
        stock = new MockERC20("STOCK", "STOCK", 18);

        // Inventory on both sides, and caps that do not bind unless a test wants them to.
        usdc.mint(address(rfq), 10_000e6);
        stock.mint(address(rfq), 100 ether);
        vm.startPrank(OWNER);
        rfq.setOutflowCap(address(usdc), 10_000e6);
        rfq.setOutflowCap(address(stock), 100 ether);
        vm.stopPrank();

        usdc.mint(TAKER, 10_000e6);
        stock.mint(TAKER, 100 ether);
        vm.startPrank(TAKER);
        usdc.approve(address(rfq), type(uint256).max);
        stock.approve(address(rfq), type(uint256).max);
        vm.stopPrank();
    }

    // ── helpers ───────────────────────────────────────────────────────────

    /// Buy 0.01 STOCK for 3.36 USDC: the shape of a $336 share.
    function _buy(uint256 nonce) internal view returns (RfqSettlement.Quote memory) {
        return RfqSettlement.Quote({
            taker: TAKER,
            tokenIn: address(usdc),
            amountIn: 3_360_000,
            tokenOut: address(stock),
            amountOut: 0.01 ether,
            nonce: nonce,
            deadline: block.timestamp + 30
        });
    }

    function _sign(RfqSettlement.Quote memory q, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, rfq.quoteDigest(q));
        return abi.encodePacked(r, s, v);
    }

    function _fill(RfqSettlement.Quote memory q, bytes memory sig) internal {
        vm.prank(TAKER);
        rfq.fill(q, sig, RECIPIENT);
    }

    // ── the digest is plain EIP-712 ───────────────────────────────────────

    /// A quote server signs off chain, so the digest has to be the standard one and not merely
    /// self-consistent. Rebuilt here from the spec, with nothing taken from the contract.
    function test_digestIsStandardEip712() public view {
        RfqSettlement.Quote memory q = _buy(7);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("RfqSettlement"),
                keccak256("1"),
                block.chainid,
                address(rfq)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Quote(address taker,address tokenIn,uint256 amountIn,address tokenOut,uint256 amountOut,uint256 nonce,uint256 deadline)"
                ),
                q.taker,
                q.tokenIn,
                q.amountIn,
                q.tokenOut,
                q.amountOut,
                q.nonce,
                q.deadline
            )
        );
        assertEq(rfq.domainSeparator(), domain);
        assertEq(rfq.quoteDigest(q), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    // ── fills ─────────────────────────────────────────────────────────────

    function test_buyFillsExactlyAsSigned() public {
        RfqSettlement.Quote memory q = _buy(1);
        _fill(q, _sign(q, signerKey));

        assertEq(usdc.balanceOf(TAKER), 10_000e6 - 3_360_000);
        assertEq(stock.balanceOf(RECIPIENT), 0.01 ether);
        assertEq(usdc.balanceOf(address(rfq)), 10_000e6 + 3_360_000);
        assertEq(stock.balanceOf(address(rfq)), 100 ether - 0.01 ether);
        assertTrue(rfq.isNonceUsed(1));
    }

    function test_sellFillsExactlyAsSigned() public {
        RfqSettlement.Quote memory q = RfqSettlement.Quote({
            taker: TAKER,
            tokenIn: address(stock),
            amountIn: 0.01 ether,
            tokenOut: address(usdc),
            amountOut: 3_350_000,
            nonce: 2,
            deadline: block.timestamp
        });
        _fill(q, _sign(q, signerKey));

        assertEq(stock.balanceOf(TAKER), 100 ether - 0.01 ether);
        assertEq(usdc.balanceOf(RECIPIENT), 3_350_000);
    }

    function test_openQuoteCanBeFilledByAnyone() public {
        RfqSettlement.Quote memory q = _buy(3);
        q.taker = address(0);
        bytes memory sig = _sign(q, signerKey);

        address stranger = address(0x5757);
        usdc.mint(stranger, 3_360_000);
        vm.startPrank(stranger);
        usdc.approve(address(rfq), type(uint256).max);
        rfq.fill(q, sig, stranger);
        vm.stopPrank();
        assertEq(stock.balanceOf(stranger), 0.01 ether);
    }

    function test_contractSignerIsAccepted() public {
        uint256 walletKey = 0xA11E7;
        OneKeyWallet wallet = new OneKeyWallet(vm.addr(walletKey));
        vm.prank(OWNER);
        rfq.setSigner(address(wallet));

        RfqSettlement.Quote memory q = _buy(4);
        _fill(q, _sign(q, walletKey));
        assertEq(stock.balanceOf(RECIPIENT), 0.01 ether);
    }

    // ── what a quote cannot be made to do ─────────────────────────────────

    function test_aTamperedQuoteFails() public {
        RfqSettlement.Quote memory q = _buy(5);
        bytes memory sig = _sign(q, signerKey);
        q.amountOut = 0.02 ether;
        vm.expectRevert(RfqSettlement.BadSignature.selector);
        _fill(q, sig);
    }

    function test_aStrangersSignatureFails() public {
        RfqSettlement.Quote memory q = _buy(6);
        bytes memory sig = _sign(q, 0xBAD);
        vm.expectRevert(RfqSettlement.BadSignature.selector);
        _fill(q, sig);
    }

    function test_aQuoteFillsOnce() public {
        RfqSettlement.Quote memory q = _buy(7);
        bytes memory sig = _sign(q, signerKey);
        _fill(q, sig);
        vm.expectRevert(abi.encodeWithSelector(RfqSettlement.NonceUsed.selector, 7));
        _fill(q, sig);
    }

    function test_aNonceIsSpentAcrossDifferentQuotes() public {
        RfqSettlement.Quote memory q = _buy(8);
        _fill(q, _sign(q, signerKey));
        q.amountOut = 0.005 ether;
        bytes memory other = _sign(q, signerKey);
        vm.expectRevert(abi.encodeWithSelector(RfqSettlement.NonceUsed.selector, 8));
        _fill(q, other);
    }

    function test_anExpiredQuoteFails() public {
        RfqSettlement.Quote memory q = _buy(9);
        bytes memory sig = _sign(q, signerKey);
        vm.warp(q.deadline + 1);
        vm.expectRevert(RfqSettlement.Expired.selector);
        _fill(q, sig);
    }

    function test_onlyTheNamedTakerCanFill() public {
        RfqSettlement.Quote memory q = _buy(10);
        bytes memory sig = _sign(q, signerKey);
        vm.expectRevert(RfqSettlement.WrongTaker.selector);
        rfq.fill(q, sig, RECIPIENT);
    }

    function test_sameTokenAndZeroRecipientAreRefused() public {
        RfqSettlement.Quote memory q = _buy(11);
        q.tokenOut = q.tokenIn;
        bytes memory sig = _sign(q, signerKey);
        vm.expectRevert(RfqSettlement.SameToken.selector);
        _fill(q, sig);

        q = _buy(12);
        sig = _sign(q, signerKey);
        vm.prank(TAKER);
        vm.expectRevert(RfqSettlement.ZeroRecipient.selector);
        rfq.fill(q, sig, address(0));
    }

    function test_anUnderpayingTokenIsCaught() public {
        SkimmingToken skim = new SkimmingToken();
        skim.mint(TAKER, 1 ether);
        vm.prank(TAKER);
        skim.approve(address(rfq), type(uint256).max);

        RfqSettlement.Quote memory q = _buy(13);
        q.tokenIn = address(skim);
        q.amountIn = 1 ether;
        bytes memory sig = _sign(q, signerKey);
        vm.expectRevert(abi.encodeWithSelector(RfqSettlement.ShortPayment.selector, 0.99 ether, 1 ether));
        _fill(q, sig);
    }

    // ── issuer controls ───────────────────────────────────────────────────

    function test_aTokenWithNoCapCannotBePaidOut() public {
        MockERC20 uncapped = new MockERC20("NEW", "NEW", 18);
        uncapped.mint(address(rfq), 1 ether);
        RfqSettlement.Quote memory q = _buy(14);
        q.tokenOut = address(uncapped);
        bytes memory sig = _sign(q, signerKey);
        vm.expectRevert(
            abi.encodeWithSelector(RfqSettlement.OutflowCapExceeded.selector, address(uncapped), 0.01 ether, 0)
        );
        _fill(q, sig);
    }

    function test_theCapBindsPerWindowAndResets() public {
        vm.prank(OWNER);
        rfq.setOutflowCap(address(stock), 0.015 ether);

        RfqSettlement.Quote memory q = _buy(15);
        _fill(q, _sign(q, signerKey));
        assertEq(rfq.remainingOutflow(address(stock)), 0.005 ether);

        q = _buy(16);
        bytes memory sig = _sign(q, signerKey);
        vm.expectRevert(
            abi.encodeWithSelector(RfqSettlement.OutflowCapExceeded.selector, address(stock), 0.01 ether, 0.005 ether)
        );
        _fill(q, sig);

        vm.warp(block.timestamp + rfq.WINDOW());
        q = _buy(16);
        _fill(q, _sign(q, signerKey));
        assertEq(rfq.remainingOutflow(address(stock)), 0.005 ether);
    }

    function test_loweringACapMidWindowBitesImmediately() public {
        RfqSettlement.Quote memory q = _buy(17);
        _fill(q, _sign(q, signerKey));
        vm.prank(OWNER);
        rfq.setOutflowCap(address(stock), 0.005 ether);
        assertEq(rfq.remainingOutflow(address(stock)), 0);
    }

    function test_theSignerCanCancelAQuoteItHandedOut() public {
        RfqSettlement.Quote memory q = _buy(300); // word 1, bit 44
        bytes memory sig = _sign(q, signerKey);
        vm.prank(signer);
        rfq.invalidateNonces(1, 1 << 44);
        vm.expectRevert(abi.encodeWithSelector(RfqSettlement.NonceUsed.selector, 300));
        _fill(q, sig);
    }

    function test_strangersCannotCancelOrPause() public {
        vm.expectRevert(RfqSettlement.NotSignerOrOwner.selector);
        rfq.invalidateNonces(0, 1);
        vm.expectRevert(RfqSettlement.NotSignerOrOwner.selector);
        rfq.setPaused(true);
    }

    function test_rotatingTheSignerVoidsEveryOutstandingQuote() public {
        RfqSettlement.Quote memory q = _buy(18);
        bytes memory sig = _sign(q, signerKey);
        vm.prank(OWNER);
        rfq.setSigner(vm.addr(0x0E11));
        vm.expectRevert(RfqSettlement.BadSignature.selector);
        _fill(q, sig);
    }

    function test_theSignerCanPauseButOnlyTheOwnerResumes() public {
        vm.prank(signer);
        rfq.setPaused(true);

        RfqSettlement.Quote memory q = _buy(19);
        bytes memory sig = _sign(q, signerKey);
        vm.expectRevert(RfqSettlement.IsPaused.selector);
        _fill(q, sig);

        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, signer));
        rfq.setPaused(false);

        vm.prank(OWNER);
        rfq.setPaused(false);
        _fill(q, sig);
    }

    function test_ownerOnlyAdmin() public {
        vm.startPrank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, TAKER));
        rfq.withdraw(address(usdc), TAKER, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, TAKER));
        rfq.setSigner(TAKER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, TAKER));
        rfq.setOutflowCap(address(usdc), 1);
        vm.stopPrank();

        vm.prank(OWNER);
        rfq.withdraw(address(usdc), OWNER, 1e6);
        assertEq(usdc.balanceOf(OWNER), 1e6);
    }

    function test_capAboveUint96IsRefused() public {
        vm.prank(OWNER);
        vm.expectRevert(RfqSettlement.CapTooLarge.selector);
        rfq.setOutflowCap(address(usdc), uint256(type(uint96).max) + 1);
    }

    // ── conservation ──────────────────────────────────────────────────────

    /// Whatever the quote says, value only moves between the taker, the recipient and the
    /// inventory, and in exactly the signed amounts.
    function testFuzz_fillConservesBalances(uint256 amountIn, uint256 amountOut, uint256 nonce) public {
        amountIn = bound(amountIn, 1, 10_000e6);
        amountOut = bound(amountOut, 1, 100 ether);
        RfqSettlement.Quote memory q = _buy(nonce);
        q.amountIn = amountIn;
        q.amountOut = amountOut;
        _fill(q, _sign(q, signerKey));

        assertEq(usdc.balanceOf(TAKER) + usdc.balanceOf(address(rfq)), 20_000e6);
        assertEq(stock.balanceOf(RECIPIENT) + stock.balanceOf(address(rfq)), 100 ether);
        assertEq(stock.balanceOf(RECIPIENT), amountOut);
    }
}
