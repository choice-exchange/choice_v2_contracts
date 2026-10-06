// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {BinLiquidityHelper} from "infinity-core/test/pool-bin/helpers/BinLiquidityHelper.sol";
import {BinTestHelper} from "infinity-core/test/pool-bin/helpers/BinTestHelper.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";

import {ChoiceAggregator} from "../src/router/ChoiceAggregator.sol";
import {MockBankERC20, MockWINJ, MockHelixSwap, MockSolidlyPair} from "./mocks/AggregatorMocks.sol";

/// A pool manager that swaps NOTHING and touches no ledger, so a stage can run to completion
/// without any vault lock existing - which is what lets `HostileStageVault` drive a first callback
/// through to the end and then try a second one.
contract InertPoolManager {
    function swap(PoolKey calldata, ICLPoolManager.SwapParams calldata, bytes calldata)
        external
        pure
        returns (BalanceDelta)
    {
        return BalanceDelta.wrap(0);
    }
}

/// An allowlisted vault that does not behave like `Vault`: the threat the payload binding exists
/// for. `Vault.lock` echoes `data` back verbatim; nothing forces a foreign vault to.
contract HostileStageVault {
    enum Mode {
        Tamper,
        Twice
    }

    ChoiceAggregator public agg;
    Mode public mode;

    function arm(ChoiceAggregator agg_, Mode mode_) external {
        agg = agg_;
        mode = mode_;
    }

    function lock(bytes calldata data) external returns (bytes memory) {
        if (mode == Mode.Tamper) {
            (ChoiceAggregator.InfinityStage memory stage, uint256 entry, uint256 stepIndex) =
                abi.decode(data, (ChoiceAggregator.InfinityStage, uint256, uint256));
            agg.lockAcquired(abi.encode(stage, entry * 2, stepIndex));
        } else {
            agg.lockAcquired(data);
            agg.lockAcquired(data);
        }
        return "";
    }

    function currencyDelta(address, Currency) external pure returns (int256) {
        return 0;
    }
}

/// Every liquidity kind the aggregator executes, each the real thing where the real thing can run
/// in a test: two independent Infinity deployments ("Choice" with CL + Bin, "Pumex" with CL) are
/// the real `Vault` + pool managers; the Solidly pair enforces its own invariant; the Helix
/// precompile is the measured mock, etched at `0x…68` where the contract calls it.
contract ChoiceAggregatorTest is BinTestHelper, DeployPermit2 {
    using CLPoolParametersHelper for bytes32;
    using BinPoolParametersHelper for bytes32;

    address internal constant TIMELOCK = address(0x71E);
    address internal constant USER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);
    address internal constant NATIVE = address(0);
    address internal constant HELIX = 0x0000000000000000000000000000000000000068;
    string internal constant INJ_USDC = "0xinj-usdc";
    string internal constant INJ_USDT_UNLISTED = "0xinj-usdt";
    uint24 internal constant FEE = 3000;
    int24 internal constant SPACING = 60;
    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;
    uint256 internal constant TICK = 1e15;

    // "Choice": CL + Bin on one vault
    Vault internal vaultA;
    CLPoolManager internal clA;
    BinPoolManager internal binA;
    CLPoolManagerRouter internal seedA;
    BinLiquidityHelper internal binSeedA;
    // "Pumex": CL only
    Vault internal vaultB;
    CLPoolManager internal clB;
    CLPoolManagerRouter internal seedB;

    IAllowanceTransfer internal permit2;
    ChoiceAggregator internal agg;

    MockWINJ internal winj;
    MockBankERC20 internal usdc;
    MockBankERC20 internal usdt;
    MockSolidlyPair internal pair; // wINJ / USDT, "Pumex V2"

    PoolKey internal poolA; // wINJ / USDC CL on Choice - thin
    PoolKey internal binPoolA; // wINJ / USDC Bin on Choice
    PoolKey internal poolB; // wINJ / USDC CL on Pumex - deep

    function setUp() public {
        vaultA = new Vault();
        clA = new CLPoolManager(vaultA);
        binA = new BinPoolManager(vaultA);
        vaultA.registerApp(address(clA));
        vaultA.registerApp(address(binA));
        seedA = new CLPoolManagerRouter(vaultA, clA);
        binSeedA = new BinLiquidityHelper(binA, vaultA);

        vaultB = new Vault();
        clB = new CLPoolManager(vaultB);
        vaultB.registerApp(address(clB));
        seedB = new CLPoolManagerRouter(vaultB, clB);

        permit2 = IAllowanceTransfer(deployPermit2());

        winj = new MockWINJ();
        usdc = new MockBankERC20("USDC", "USDC", 18);
        usdt = new MockBankERC20("USDT", "USDT", 18);

        IVault[] memory vaults = new IVault[](2);
        vaults[0] = vaultA;
        vaults[1] = vaultB;
        agg = new ChoiceAggregator(TIMELOCK, permit2, IWETH9(address(winj)), vaults);

        poolA = _clKey(clA, address(winj), address(usdc));
        poolB = _clKey(clB, address(winj), address(usdc));
        binPoolA = _binKey(binA, address(winj), address(usdc));
        _seedCl(seedA, clA, poolA, 100_000 ether);
        _seedCl(seedB, clB, poolB, 1_000_000 ether);
        _seedBin(binPoolA, 10_000 ether);

        (address p0, address p1) = _sorted(address(winj), address(usdt));
        pair = new MockSolidlyPair(p0, p1, 18);
        winj.mint(address(pair), 1_000_000 ether);
        usdt.mint(address(pair), 1_000_000 ether);
        pair.sync();

        vm.etch(HELIX, address(new MockHelixSwap()).code);
        MockHelixSwap(HELIX).setMarket(INJ_USDC, _market(address(usdc), true));
        MockHelixSwap(HELIX).setMarket(INJ_USDT_UNLISTED, _market(address(usdt), false));

        // Every wINJ in this suite is minted rather than deposited, so the wrapper holds no native
        // to pay an unwrap with. Back the whole supply, as the real one is.
        vm.deal(address(winj), winj.totalSupply() + 1_000_000 ether);

        vm.deal(USER, 1_000_000 ether);
        address[3] memory tokens = [address(winj), address(usdc), address(usdt)];
        for (uint256 i; i < tokens.length; ++i) {
            MockBankERC20(tokens[i]).mint(USER, 1_000_000 ether);
            vm.startPrank(USER);
            MockBankERC20(tokens[i]).approve(address(permit2), type(uint256).max);
            permit2.approve(tokens[i], address(agg), type(uint160).max, type(uint48).max);
            vm.stopPrank();
        }
    }

    // ── the venues ────────────────────────────────────────────────────────

    /// The precompile floors a fill to the market's quantity tick and leaves the rest with the
    /// caller. Here the caller is the aggregator, so the remainder is route money - and it must
    /// come back to the user as native INJ rather than sit in the contract.
    function test_aHelixSellPaysTheQuoteAndRefundsTheTickRemainder() public {
        uint256 amountIn = 100 ether + 123;
        uint256 quoted = MockHelixSwap(HELIX).quoteExactInputV1(NATIVE, INJ_USDC, amountIn);

        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](1);
        steps[0] = _helix(NATIVE, address(usdc), 10_000, INJ_USDC);
        ChoiceAggregator.RouteParams memory p = _params(NATIVE, address(usdc), amountIn, quoted, steps);

        uint256 userBefore = USER.balance;
        uint256 got = _run(p);

        assertEq(got, quoted, "the Helix fill was not the quote");
        assertEq(usdc.balanceOf(RECIPIENT), quoted, "recipient was not paid");
        assertEq(USER.balance, userBefore - 100 ether, "the tick remainder did not come back");
        _assertRouterEmpty();
    }

    /// Past the book's depth the precompile fills PARTIALLY and does not revert. The end-to-end
    /// minimum is what stands between that and a user receiving 40% of what was quoted.
    function test_aPartialHelixFillIsCaughtByTheEndToEndMinimum() public {
        uint256 amountIn = 100 ether;
        uint256 quoted = MockHelixSwap(HELIX).quoteExactInputV1(NATIVE, INJ_USDC, amountIn);
        _setBidDepth(40 ether);
        uint256 partialOut = MockHelixSwap(HELIX).quoteExactInputV1(NATIVE, INJ_USDC, amountIn);

        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](1);
        steps[0] = _helix(NATIVE, address(usdc), 10_000, INJ_USDC);
        ChoiceAggregator.RouteParams memory p = _params(NATIVE, address(usdc), amountIn, quoted, steps);

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(ChoiceAggregator.InsufficientOutput.selector, partialOut, quoted));
        agg.execute{value: amountIn}(p);
    }

    /// The same partial fill under a minimum it does meet: the unfilled input is the user's.
    function test_aPartialHelixFillRefundsTheUnfilledInput() public {
        _setBidDepth(40 ether);
        uint256 partialOut = MockHelixSwap(HELIX).quoteExactInputV1(NATIVE, INJ_USDC, 100 ether);

        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](1);
        steps[0] = _helix(NATIVE, address(usdc), 10_000, INJ_USDC);
        ChoiceAggregator.RouteParams memory p = _params(NATIVE, address(usdc), 100 ether, partialOut, steps);

        uint256 userBefore = USER.balance;
        _run(p);

        assertEq(USER.balance, userBefore - 40 ether, "the unfilled 60 INJ did not come back");
        _assertRouterEmpty();
    }

    /// The shape the 2026-10-07 measurement asked for: part of a native INJ sell on the Helix
    /// book, the rest wrapped and sold into a FOREIGN vault, under one minimum. `ChoiceRouter`
    /// cannot express this - no orderbook leg, and no route that skips Choice's vault.
    function test_aSplitAcrossHelixAndAForeignVaultHonoursOneMinimum() public {
        uint256 amountIn = 1000 ether;
        ChoiceAggregator.RouteParams memory p = _params(NATIVE, address(usdc), amountIn, 0, _helixPumexSplit(6000));

        uint256 realised = _probe(p);
        uint256 helixPart = MockHelixSwap(HELIX).quoteExactInputV1(NATIVE, INJ_USDC, 600 ether);
        assertGt(realised, helixPart, "the Pumex leg added nothing");

        p.minimumReceive = realised;
        uint256 got = _run(p);

        assertEq(got, realised, "realised output moved between the probe and the run");
        assertEq(usdc.balanceOf(RECIPIENT), realised, "recipient was not paid the output");
        _assertRouterEmpty();
    }

    /// `ChoiceRouter` reverts `NotCrossVault` on this. A route entirely inside Pumex is the best
    /// USDC->INJ path on mainnet today, so here it is a route like any other.
    function test_aRouteEntirelyInsideAForeignVaultIsAllowed() public {
        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](1);
        steps[0] = _infinity(vaultB, poolB, false, address(winj), address(usdc), 10_000);
        ChoiceAggregator.RouteParams memory p = _params(address(winj), address(usdc), 1000 ether, 0, steps);

        uint256 realised = _probe(p);
        p.minimumReceive = realised;
        assertEq(_run(p), realised);
        assertEq(winj.balanceOf(USER), 1_000_000 ether - 1000 ether, "wrong amount was pulled");
        _assertRouterEmpty();
    }

    /// A Solidly pair is asked for its own output, paid by transfer, and swapped. The pair
    /// ENFORCES its invariant here, so asking the wrong side or under-sending would revert.
    /// Then an unwrap, so the recipient gets native INJ.
    function test_aSolidlyPairThenUnwrapPaysNativeInj() public {
        uint256 amountIn = 5000 ether;
        uint256 quoted = pair.getAmountOut(amountIn, address(usdt));

        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](2);
        steps[0] = _solidly(address(usdt), address(winj), 10_000);
        steps[1] = _unwrap(10_000);
        ChoiceAggregator.RouteParams memory p = _params(address(usdt), NATIVE, amountIn, quoted, steps);

        uint256 recipientBefore = RECIPIENT.balance;
        uint256 got = _run(p);

        assertEq(got, quoted, "the pair did not pay its own quote");
        assertEq(RECIPIENT.balance - recipientBefore, quoted, "recipient was not paid native INJ");
        _assertRouterEmpty();
    }

    function test_aBinHopSwapsThroughTheBinManager() public {
        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](1);
        steps[0] = _infinity(vaultA, binPoolA, true, address(winj), address(usdc), 10_000);
        ChoiceAggregator.RouteParams memory p = _params(address(winj), address(usdc), 100 ether, 0, steps);

        uint256 realised = _probe(p);
        assertGt(realised, 0, "the bin pool paid nothing");
        p.minimumReceive = realised;
        assertEq(_run(p), realised);
        _assertRouterEmpty();
    }

    /// A handoff across kinds: Choice's vault, then a Solidly pair, the intermediate held by the
    /// router between them. USDC -> wINJ -> USDT, the route a wINJ/USDT-less Choice needs.
    function test_aHandoffFromAVaultToASolidlyPair() public {
        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](2);
        steps[0] = _infinity(vaultA, poolA, false, address(usdc), address(winj), 10_000);
        steps[1] = _solidly(address(winj), address(usdt), 10_000);
        ChoiceAggregator.RouteParams memory p = _params(address(usdc), address(usdt), 1000 ether, 0, steps);

        uint256 realised = _probe(p);
        p.minimumReceive = realised;
        assertEq(_run(p), realised);
        assertEq(usdt.balanceOf(RECIPIENT), realised);
        _assertRouterEmpty();
    }

    /// 🔑 USDC as a Helix `tokenIn`. The real v1.20.4 precompile refuses this (an Injective bug
    /// in its denom resolver); the mock models the chain after the fix. The point: the contract
    /// passes the token straight through, so the fix needs no new contract - the route the
    /// backend emits is this calldata, and it starts working the block the fix ships.
    function test_aUsdcHelixBuyNeedsNoSpecialCase() public {
        uint256 amountIn = 1000 ether;
        uint256 quoted = MockHelixSwap(HELIX).quoteExactInputV1(address(usdc), INJ_USDC, amountIn);

        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](2);
        steps[0] = _helix(address(usdc), NATIVE, 10_000, INJ_USDC);
        steps[1] = _wrap(10_000);
        ChoiceAggregator.RouteParams memory p = _params(address(usdc), address(winj), amountIn, quoted, steps);

        uint256 got = _run(p);
        assertEq(got, quoted, "the Helix buy was not the quote");
        assertEq(winj.balanceOf(RECIPIENT), quoted, "recipient was not paid wINJ");
        assertLt(1_000_000 ether - usdc.balanceOf(USER), amountIn + 1, "more USDC than amountIn left the user");
        _assertRouterEmpty();
    }

    function test_anUnlistedHelixMarketRevertsTheRoute() public {
        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](1);
        steps[0] = _helix(NATIVE, address(usdt), 10_000, INJ_USDT_UNLISTED);
        ChoiceAggregator.RouteParams memory p = _params(NATIVE, address(usdt), 10 ether, 0, steps);

        vm.prank(USER);
        vm.expectRevert(bytes("market is not allowlisted for swaps: invalid swap route"));
        agg.execute{value: 10 ether}(p);
    }

    /// Whatever the split, the route ends with nothing of its own left in the router: every unit
    /// went to the recipient as output or back to the caller as dust.
    function testFuzz_aSplitLeavesNoRouteMoneyBehind(uint256 amountIn, uint16 helixBps) public {
        amountIn = bound(amountIn, 10 ether, 10_000 ether);
        helixBps = uint16(bound(helixBps, 1, 9_999));

        ChoiceAggregator.RouteParams memory p = _params(NATIVE, address(usdc), amountIn, 0, _helixPumexSplit(helixBps));
        uint256 got = _run(p);

        assertEq(usdc.balanceOf(RECIPIENT), got, "recipient was not paid what the route produced");
        assertGt(got, 0);
        _assertRouterEmpty();
    }

    // ── the trust boundary ────────────────────────────────────────────────

    function test_aVaultOutsideTheAllowlistIsRefused() public {
        Vault rogue = new Vault();
        CLPoolManager rogueManager = new CLPoolManager(rogue);
        rogue.registerApp(address(rogueManager));

        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](1);
        steps[0] = _infinity(rogue, poolB, false, address(winj), address(usdc), 10_000);
        ChoiceAggregator.RouteParams memory p = _params(address(winj), address(usdc), 1 ether, 0, steps);

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(ChoiceAggregator.VaultNotAllowed.selector, address(rogue)));
        agg.execute(p);
    }

    function test_lockAcquiredIsRefusedOutsideARoute() public {
        vm.prank(address(vaultA));
        vm.expectRevert(ChoiceAggregator.NotVault.selector);
        agg.lockAcquired("");

        vm.prank(USER);
        vm.expectRevert(ChoiceAggregator.NotVault.selector);
        agg.lockAcquired("");
    }

    /// Audit R-1, carried over from `ChoiceRouter`: a vault that hands back a different stage.
    function test_aVaultThatEchoesADifferentStageIsRefused() public {
        ChoiceAggregator.RouteParams memory p = _hostileRoute(HostileStageVault.Mode.Tamper);

        vm.prank(USER);
        vm.expectRevert(ChoiceAggregator.StagePayloadMismatch.selector);
        agg.execute(p);
    }

    /// The payload is single-use per lock. The first callback SUCCEEDS (against a manager that
    /// moves nothing), so the second is a genuine second call and not a first that rolled back.
    function test_theSamePayloadCannotDriveTwoCallbacksInOneLock() public {
        ChoiceAggregator.RouteParams memory p = _hostileRoute(HostileStageVault.Mode.Twice);

        vm.prank(USER);
        vm.expectRevert(ChoiceAggregator.StagePayloadMismatch.selector);
        agg.execute(p);
    }

    function test_onlyTheOwnerCanChangeTheAllowlist() public {
        Vault other = new Vault();

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER));
        agg.setVault(other, true);

        vm.prank(TIMELOCK);
        agg.setVault(other, true);
        assertTrue(agg.allowedVault(address(other)));

        vm.prank(TIMELOCK);
        agg.setVault(vaultB, false);
        assertFalse(agg.allowedVault(address(vaultB)));
    }

    function test_ownerIsTheTimelockAndBothVaultsAreBornAllowed() public view {
        assertEq(agg.owner(), TIMELOCK);
        assertTrue(agg.allowedVault(address(vaultA)));
        assertTrue(agg.allowedVault(address(vaultB)));
        assertEq(address(agg.WINJ()), address(winj));
        assertEq(address(agg.HELIX()), HELIX);
    }

    /// Native INJ sent by anyone but wINJ, an allowlisted vault or the precompile would be a
    /// donation no route can spend and no one can recover.
    function test_strayNativeIsRefused() public {
        vm.deal(USER, 1 ether);
        vm.prank(USER);
        (bool ok, bytes memory ret) = address(agg).call{value: 1 ether}("");
        assertFalse(ok, "a stray send was accepted");
        assertEq(bytes4(ret), ChoiceAggregator.NativeNotAccepted.selector);
    }

    // ── accounting ────────────────────────────────────────────────────────

    /// A balance the router already held is invisible: neither spendable as route input nor
    /// payable as output nor sweepable as dust - in an ERC20 and in native INJ alike.
    function test_aDonationIsNeitherSpentNorSwept() public {
        usdc.mint(address(agg), 77 ether);
        winj.mint(address(agg), 13 ether);
        vm.deal(address(agg), 5 ether);

        ChoiceAggregator.RouteParams memory p = _params(NATIVE, address(usdc), 1000 ether, 0, _helixPumexSplit(5000));
        uint256 realised = _probe(p);
        p.minimumReceive = realised;
        uint256 got = _run(p);

        assertEq(got, realised);
        assertEq(usdc.balanceOf(RECIPIENT), realised, "recipient received the donation");
        assertEq(usdc.balanceOf(address(agg)), 77 ether, "the USDC donation moved");
        assertEq(winj.balanceOf(address(agg)), 13 ether, "the wINJ donation moved");
        assertEq(address(agg).balance, 5 ether, "the native donation moved");
    }

    function test_unspentInputComesBackToTheCaller() public {
        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](1);
        steps[0] = _infinity(vaultB, poolB, false, address(winj), address(usdc), 6000);
        ChoiceAggregator.RouteParams memory p = _params(address(winj), address(usdc), 1000 ether, 0, steps);

        _run(p);
        assertEq(winj.balanceOf(USER), 1_000_000 ether - 600 ether, "the 40% left unspent did not come back");
        _assertRouterEmpty();
    }

    function test_aStepOnATokenTheRouteDoesNotHoldReverts() public {
        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](1);
        steps[0] = _solidly(address(usdt), address(winj), 10_000);
        ChoiceAggregator.RouteParams memory p = _params(address(usdc), address(winj), 1 ether, 0, steps);

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(ChoiceAggregator.StepInputEmpty.selector, 0));
        agg.execute(p);
    }

    /// A step that names the wrong output - here the pair pays USDT and the step claims USDC -
    /// reverts on the spot instead of stranding the real output.
    function test_aStepThatProducesNothingItNamedReverts() public {
        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](1);
        steps[0] = _solidly(address(winj), address(usdc), 10_000);
        ChoiceAggregator.RouteParams memory p = _params(address(winj), address(usdc), 1 ether, 0, steps);

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(ChoiceAggregator.StepPaidNothing.selector, 0));
        agg.execute(p);
    }

    function test_aRecipientThatRefusesNativeInjRevertsTheRoute() public {
        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](2);
        steps[0] = _solidly(address(usdt), address(winj), 10_000);
        steps[1] = _unwrap(10_000);
        ChoiceAggregator.RouteParams memory p = _params(address(usdt), NATIVE, 1 ether, 0, steps);
        p.recipient = address(permit2);

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(ChoiceAggregator.NativeTransferFailed.selector, address(permit2)));
        agg.execute(p);
    }

    // ── malformed routes ──────────────────────────────────────────────────

    function test_malformedEnvelopesAreRefused() public {
        ChoiceAggregator.Step[] memory one = new ChoiceAggregator.Step[](1);
        one[0] = _infinity(vaultB, poolB, false, address(winj), address(usdc), 10_000);

        ChoiceAggregator.RouteParams memory p = _params(address(winj), address(usdc), 1 ether, 0, one);
        p.deadline = block.timestamp - 1;
        _expectRevert(p, 0, abi.encodeWithSelector(ChoiceAggregator.DeadlinePassed.selector));

        p = _params(address(winj), address(usdc), 1 ether, 0, new ChoiceAggregator.Step[](0));
        _expectRevert(p, 0, abi.encodeWithSelector(ChoiceAggregator.NoSteps.selector));

        p = _params(address(winj), address(usdc), 0, 0, one);
        _expectRevert(p, 0, abi.encodeWithSelector(ChoiceAggregator.ZeroAmount.selector));

        p = _params(address(winj), address(usdc), 1 ether, 0, one);
        p.recipient = address(0);
        _expectRevert(p, 0, abi.encodeWithSelector(ChoiceAggregator.ZeroRecipient.selector));

        p = _params(address(winj), address(winj), 1 ether, 0, one);
        _expectRevert(p, 0, abi.encodeWithSelector(ChoiceAggregator.SameCurrency.selector));

        p = _params(address(winj), address(usdc), 1 ether, 0, one);
        _expectRevert(p, 1, abi.encodeWithSelector(ChoiceAggregator.ValueMismatch.selector, 1, 0));

        ChoiceAggregator.Step[] memory h = new ChoiceAggregator.Step[](1);
        h[0] = _helix(NATIVE, address(usdc), 10_000, INJ_USDC);
        p = _params(NATIVE, address(usdc), 1 ether, 0, h);
        _expectRevert(
            p, 1 ether - 1, abi.encodeWithSelector(ChoiceAggregator.ValueMismatch.selector, 1 ether - 1, 1 ether)
        );
    }

    function test_malformedStepsAreRefused() public {
        ChoiceAggregator.Step[] memory s = new ChoiceAggregator.Step[](1);
        ChoiceAggregator.RouteParams memory p;

        s[0] = _infinity(vaultB, poolB, false, address(winj), address(usdc), 0);
        p = _params(address(winj), address(usdc), 1 ether, 0, s);
        _expectRevert(p, 0, abi.encodeWithSelector(ChoiceAggregator.BadShare.selector, 0));

        s[0] = _infinity(vaultB, poolB, false, address(winj), address(usdc), 10_001);
        _expectRevert(p, 0, abi.encodeWithSelector(ChoiceAggregator.BadShare.selector, 0));

        // A Wrap that does not go native -> wINJ.
        s[0] = ChoiceAggregator.Step({
            kind: ChoiceAggregator.Kind.Wrap, tokenIn: NATIVE, tokenOut: address(usdc), shareBps: 10_000, data: ""
        });
        p = _params(NATIVE, address(usdc), 1 ether, 0, s);
        _expectRevert(p, 1 ether, abi.encodeWithSelector(ChoiceAggregator.BadStep.selector, 0));

        // The precompile's INJ is address(0); a Helix step naming wINJ is malformed.
        s[0] = _helix(address(winj), address(usdc), 10_000, INJ_USDC);
        p = _params(address(winj), address(usdc), 1 ether, 0, s);
        _expectRevert(p, 0, abi.encodeWithSelector(ChoiceAggregator.BadStep.selector, 0));

        // A Solidly pair never takes native INJ.
        s[0] = _solidly(NATIVE, address(usdt), 10_000);
        p = _params(NATIVE, address(usdt), 1 ether, 0, s);
        _expectRevert(p, 1 ether, abi.encodeWithSelector(ChoiceAggregator.BadStep.selector, 0));

        // A step from a token to itself.
        s[0] = _solidly(address(winj), address(winj), 10_000);
        p = _params(address(winj), address(usdc), 1 ether, 0, s);
        _expectRevert(p, 0, abi.encodeWithSelector(ChoiceAggregator.BadStep.selector, 0));
    }

    /// A stage spends its step's input and nothing else: every share-taking hop must spend the
    /// step's `tokenIn`, the shares may not exceed the entry, and the first hop cannot chain.
    function test_aStageCannotSpendMoneyTheStepDoesNotOwn() public {
        ChoiceAggregator.Step[] memory s = new ChoiceAggregator.Step[](1);
        ChoiceAggregator.RouteParams memory p;

        // Step says wINJ, hop spends USDC.
        s[0] = _infinity(vaultB, poolB, false, address(winj), address(usdc), 10_000);
        ChoiceAggregator.InfinityStage memory stage = abi.decode(s[0].data, (ChoiceAggregator.InfinityStage));
        stage.hops[0].zeroForOne = !stage.hops[0].zeroForOne;
        s[0].data = abi.encode(stage);
        p = _params(address(winj), address(usdc), 1 ether, 0, s);
        _expectRevert(p, 0, abi.encodeWithSelector(ChoiceAggregator.HopInputMismatch.selector, 0, 0));

        // Two hops at 60% each.
        ChoiceAggregator.Hop[] memory hops = new ChoiceAggregator.Hop[](2);
        hops[0] = _hopFor(poolB, false, address(winj), 6000);
        hops[1] = _hopFor(poolB, false, address(winj), 6000);
        s[0].data = abi.encode(ChoiceAggregator.InfinityStage({vault: vaultB, hops: hops}));
        _expectRevert(p, 0, abi.encodeWithSelector(ChoiceAggregator.StageOverAllocated.selector, 0));

        // A first hop that chains on a delta nothing has produced yet.
        ChoiceAggregator.Hop[] memory first = new ChoiceAggregator.Hop[](1);
        first[0] = _hopFor(poolB, false, address(winj), 0);
        s[0].data = abi.encode(ChoiceAggregator.InfinityStage({vault: vaultB, hops: first}));
        _expectRevert(p, 0, abi.encodeWithSelector(ChoiceAggregator.NothingToChain.selector, 0, 0));
    }

    /// @dev Both slots are literals because inline assembly cannot reference a computed constant,
    /// so this is the only thing standing between a mistyped nibble and two gates that silently
    /// read the wrong word. They are also distinct from `ChoiceRouter`'s.
    function test_transientSlotsMatchTheirDerivation() public pure {
        bytes32 active = bytes32(uint256(keccak256("choice.v2.aggregator.activeVault")) - 1);
        bytes32 payload = bytes32(uint256(keccak256("choice.v2.aggregator.stagePayload")) - 1);
        assertEq(active, 0x521ef52308a276606f192773ee4e5066279c751ae60ace30d9dbdedbc40c6b7d);
        assertEq(payload, 0xbd74014f058beb366b185ec0ddc5288621cbbba0a9f626076702bc8a4fe16b2b);
        assertTrue(active != payload, "the two gates would share one word");
    }

    // ── helpers ───────────────────────────────────────────────────────────

    /// Native INJ -> `helixBps` on the Helix book, the rest wrapped and sold on Pumex's CL pool.
    function _helixPumexSplit(uint16 helixBps) internal view returns (ChoiceAggregator.Step[] memory steps) {
        steps = new ChoiceAggregator.Step[](3);
        steps[0] = _helix(NATIVE, address(usdc), helixBps, INJ_USDC);
        steps[1] = _wrap(10_000);
        steps[2] = _infinity(vaultB, poolB, false, address(winj), address(usdc), 10_000);
    }

    function _hostileRoute(HostileStageVault.Mode mode) internal returns (ChoiceAggregator.RouteParams memory p) {
        HostileStageVault hostile = new HostileStageVault();
        hostile.arm(agg, mode);
        InertPoolManager silent = new InertPoolManager();

        vm.prank(TIMELOCK);
        agg.setVault(IVault(address(hostile)), true);

        PoolKey memory silentKey = _clKey(CLPoolManager(address(silent)), address(winj), address(usdc));
        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](1);
        steps[0] = _infinity(IVault(address(hostile)), silentKey, false, address(winj), address(usdc), 10_000);
        p = _params(address(winj), address(usdc), 1000 ether, 0, steps);
    }

    function _run(ChoiceAggregator.RouteParams memory p) internal returns (uint256) {
        vm.prank(USER);
        return agg.execute{value: p.currencyIn == NATIVE ? p.amountIn : 0}(p);
    }

    /// Runs the route under an unreachable minimum and reads the realised output back out of the
    /// revert, so expectations are the chain's own numbers.
    ///
    /// 🔴 Wrapped in a state snapshot, because the revert alone does NOT roll everything back
    /// here: the precompile mock moves native INJ with `vm.deal`, and a cheatcode write inside a
    /// call that later reverts survives the revert. Without the snapshot the next call through the
    /// same route fails `OverflowPayment` on balances the probe left behind.
    function _probe(ChoiceAggregator.RouteParams memory p) internal returns (uint256 realised) {
        uint256 snap = vm.snapshotState();
        uint256 keep = p.minimumReceive;
        p.minimumReceive = type(uint256).max;
        vm.prank(USER);
        try agg.execute{value: p.currencyIn == NATIVE ? p.amountIn : 0}(p) returns (uint256) {
            revert("probe should not have succeeded");
        } catch (bytes memory err) {
            assertEq(bytes4(err), ChoiceAggregator.InsufficientOutput.selector, "probe reverted for another reason");
            (realised,) = abi.decode(_body(err), (uint256, uint256));
        }
        p.minimumReceive = keep;
        vm.revertToState(snap);
    }

    function _expectRevert(ChoiceAggregator.RouteParams memory p, uint256 value, bytes memory err) internal {
        vm.prank(USER);
        vm.expectRevert(err);
        agg.execute{value: value}(p);
    }

    function _assertRouterEmpty() internal view {
        assertEq(address(agg).balance, 0, "native INJ left in the router");
        assertEq(winj.balanceOf(address(agg)), 0, "wINJ left in the router");
        assertEq(usdc.balanceOf(address(agg)), 0, "USDC left in the router");
        assertEq(usdt.balanceOf(address(agg)), 0, "USDT left in the router");
    }

    function _body(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = err[i + 4];
        }
    }

    function _params(
        address currencyIn,
        address currencyOut,
        uint256 amountIn,
        uint256 minimumReceive,
        ChoiceAggregator.Step[] memory steps
    ) internal view returns (ChoiceAggregator.RouteParams memory) {
        return ChoiceAggregator.RouteParams({
            currencyIn: currencyIn,
            currencyOut: currencyOut,
            amountIn: amountIn,
            minimumReceive: minimumReceive,
            recipient: RECIPIENT,
            deadline: block.timestamp + 1,
            steps: steps
        });
    }

    function _helix(address tokenIn, address tokenOut, uint16 shareBps, string memory market)
        internal
        pure
        returns (ChoiceAggregator.Step memory)
    {
        return ChoiceAggregator.Step({
            kind: ChoiceAggregator.Kind.Helix,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            shareBps: shareBps,
            data: abi.encode(market)
        });
    }

    function _wrap(uint16 shareBps) internal view returns (ChoiceAggregator.Step memory) {
        return ChoiceAggregator.Step({
            kind: ChoiceAggregator.Kind.Wrap, tokenIn: NATIVE, tokenOut: address(winj), shareBps: shareBps, data: ""
        });
    }

    function _unwrap(uint16 shareBps) internal view returns (ChoiceAggregator.Step memory) {
        return ChoiceAggregator.Step({
            kind: ChoiceAggregator.Kind.Unwrap, tokenIn: address(winj), tokenOut: NATIVE, shareBps: shareBps, data: ""
        });
    }

    function _solidly(address tokenIn, address tokenOut, uint16 shareBps)
        internal
        view
        returns (ChoiceAggregator.Step memory)
    {
        return ChoiceAggregator.Step({
            kind: ChoiceAggregator.Kind.Solidly,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            shareBps: shareBps,
            data: abi.encode(address(pair), tokenIn == pair.token0())
        });
    }

    function _infinity(IVault vault, PoolKey memory key, bool bin, address tokenIn, address tokenOut, uint16 shareBps)
        internal
        pure
        returns (ChoiceAggregator.Step memory)
    {
        ChoiceAggregator.Hop[] memory hops = new ChoiceAggregator.Hop[](1);
        hops[0] = _hopFor(key, bin, tokenIn, 10_000);
        return ChoiceAggregator.Step({
            kind: ChoiceAggregator.Kind.Infinity,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            shareBps: shareBps,
            data: abi.encode(ChoiceAggregator.InfinityStage({vault: vault, hops: hops}))
        });
    }

    function _hopFor(PoolKey memory key, bool bin, address tokenIn, uint16 entryBps)
        internal
        pure
        returns (ChoiceAggregator.Hop memory)
    {
        return ChoiceAggregator.Hop({
            key: key, zeroForOne: Currency.unwrap(key.currency0) == tokenIn, bin: bin, entryBps: entryBps, hookData: ""
        });
    }

    function _market(address quote, bool allowed) internal pure returns (MockHelixSwap.Market memory) {
        return MockHelixSwap.Market({
            base: NATIVE,
            quote: quote,
            bidE18: 1e18,
            askE18: 1.001e18,
            bidDepth: 1_000_000 ether,
            askDepth: 1_000_000 ether,
            qtyTick: TICK,
            feeE18: 1e15,
            allowed: allowed
        });
    }

    function _setBidDepth(uint256 depth) internal {
        MockHelixSwap.Market memory m = _market(address(usdc), true);
        m.bidDepth = depth;
        MockHelixSwap(HELIX).setMarket(INJ_USDC, m);
    }

    function _sorted(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    function _clKey(CLPoolManager manager, address a, address b) internal pure returns (PoolKey memory) {
        (address c0, address c1) = _sorted(a, b);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(manager)),
            fee: FEE,
            parameters: bytes32(0).setTickSpacing(SPACING)
        });
    }

    function _binKey(BinPoolManager manager, address a, address b) internal pure returns (PoolKey memory) {
        (address c0, address c1) = _sorted(a, b);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(manager)),
            fee: FEE,
            parameters: bytes32(0).setBinStep(DEFAULT_BIN_STEP)
        });
    }

    function _seedCl(CLPoolManagerRouter seeder, CLPoolManager manager, PoolKey memory key, uint256 amount) internal {
        manager.initialize(key, SQRT_1_1);
        MockBankERC20(Currency.unwrap(key.currency0)).mint(address(this), amount);
        MockBankERC20(Currency.unwrap(key.currency1)).mint(address(this), amount);
        MockBankERC20(Currency.unwrap(key.currency0)).approve(address(seeder), type(uint256).max);
        MockBankERC20(Currency.unwrap(key.currency1)).approve(address(seeder), type(uint256).max);
        seeder.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(amount / 2), salt: bytes32(0)
            }),
            ""
        );
    }

    function _seedBin(PoolKey memory key, uint256 amount) internal {
        binA.initialize(key, ID_ONE);
        MockBankERC20(Currency.unwrap(key.currency0)).mint(address(this), amount);
        MockBankERC20(Currency.unwrap(key.currency1)).mint(address(this), amount);
        MockBankERC20(Currency.unwrap(key.currency0)).approve(address(binSeedA), type(uint256).max);
        MockBankERC20(Currency.unwrap(key.currency1)).approve(address(binSeedA), type(uint256).max);
        (IBinPoolManager.MintParams memory mp,) = _getMultipleBinMintParams(ID_ONE, amount, amount, 10, 10);
        binSeedA.mint(key, mp, "");
    }
}
