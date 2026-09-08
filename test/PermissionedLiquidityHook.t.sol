// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {HOOKS_BEFORE_MINT_OFFSET} from "infinity-core/src/pool-bin/interfaces/IBinHooks.sol";
import {HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {BinPosition} from "infinity-core/src/pool-bin/libraries/BinPosition.sol";
import {BinTestHelper} from "infinity-core/test/pool-bin/helpers/BinTestHelper.sol";
import {BinLiquidityHelper} from "infinity-core/test/pool-bin/helpers/BinLiquidityHelper.sol";
import {BinSwapHelper} from "infinity-core/test/pool-bin/helpers/BinSwapHelper.sol";

import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {BinPositionManager} from "infinity-periphery/src/pool-bin/BinPositionManager.sol";
import {IBinPositionManager} from "infinity-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";

import {PermissionedLiquidityHook} from "../src/hooks/PermissionedLiquidityHook.sol";

/// @notice The hook that makes a pool's LP set an allowlist, and the one way to arm it wrongly.
///
/// Two things are worth proving here and only one of them is the happy path. The gate itself is
/// three lines and hard to get wrong. What is easy to get wrong is WHO the gate sees: both
/// dispatchers pass the `msg.sender` of the pool manager call, so allowlisting a shared
/// entry point hands the pool to everyone who can reach it - while every test a careful person
/// would write still passes. `test_allowlistingThePositionManagerFailsOpen` plants that mistake
/// with the REAL `BinPositionManager` and asserts the pool opens up.
contract PermissionedLiquidityHookTest is Test, BinTestHelper, DeployPermit2 {
    using BinPoolParametersHelper for bytes32;
    using Planner for Plan;

    address internal constant TIMELOCK = address(0x7175);
    address internal constant STRANGER = address(0x5747);
    uint16 internal constant BIN_STEP = 10;
    uint24 internal constant LP_FEE = 3000;
    uint24 internal constant ACTIVE_ID = 2 ** 23;

    Vault internal vault;
    BinPoolManager internal poolManager;
    PermissionedLiquidityHook internal hook;

    /// @dev An allowlisted provider: a contract that takes the vault lock itself and calls
    /// `binManager.mint` directly, which is the shape an allowlisted provider MUST have.
    BinLiquidityHelper internal provider;
    BinSwapHelper internal swapHelper;
    BinPositionManager internal posm;
    IAllowanceTransfer internal permit2;

    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal key;
    PoolId internal poolId;

    function setUp() public {
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)));
        vault.registerApp(address(poolManager));

        provider = new BinLiquidityHelper(poolManager, IVault(address(vault)));
        swapHelper = new BinSwapHelper(poolManager, IVault(address(vault)));
        permit2 = IAllowanceTransfer(deployPermit2());
        posm = new BinPositionManager(IVault(address(vault)), poolManager, permit2, IWETH9(address(new WETH())));

        hook = new PermissionedLiquidityHook(TIMELOCK, address(provider));

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            hooks: IHooks(address(hook)),
            poolManager: IPoolManager(address(poolManager)),
            fee: LP_FEE,
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setBinStep(BIN_STEP)
        });
        poolId = key.toId();
        poolManager.initialize(key, ACTIVE_ID);

        _fund(address(this));
        _fund(STRANGER);
    }

    function _fund(address who) internal {
        token0.mint(who, 1_000 ether);
        token1.mint(who, 1_000 ether);
        vm.startPrank(who);
        token0.approve(address(provider), type(uint256).max);
        token1.approve(address(provider), type(uint256).max);
        token0.approve(address(swapHelper), type(uint256).max);
        token1.approve(address(swapHelper), type(uint256).max);
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token0), address(posm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(posm), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @dev Mint through the allowlisted provider. `BinLiquidityHelper` pulls the tokens from
    /// whoever called it, so `caller` funds the position and `provider` is what the hook sees.
    function _mintVia(address caller, uint256 amount) internal {
        IBinPoolManager.MintParams memory params = _getSingleBinMintParams(ACTIVE_ID, amount, amount);
        vm.prank(caller);
        provider.mint(key, params, "");
    }

    // ── the permission set ────────────────────────────────────────────────

    /// @dev The whole safety argument rests on this number. Bit 2 and nothing else: no swap bit,
    /// no burn bit, no initialize bit, so the hook is structurally unreachable on any of them.
    function test_bitmapIsAddLiquidityOnly() public view {
        assertEq(hook.BITMAP(), uint16(1 << 2), "bitmap must be the add-liquidity bit alone");
        assertEq(hook.getHooksRegistrationBitmap(), hook.BITMAP(), "registration must match the constant");
    }

    /// @dev One contract serves CL and Bin only because upstream numbers the two callbacks at
    /// the same bit. If a version bump ever separates them this fails rather than silently
    /// registering the wrong callback for one of the two pool types.
    function test_theTwoPoolTypesShareTheAddLiquidityBit() public pure {
        assertEq(
            uint256(HOOKS_BEFORE_MINT_OFFSET),
            uint256(HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET),
            "bin beforeMint and cl beforeAddLiquidity must share a bit"
        );
    }

    /// @dev The bitmap is a promise the POOL MANAGER enforces, not one the hook makes. A key
    /// claiming any other permission set cannot be initialised at all.
    function test_poolManagerRejectsAKeyClaimingAnotherBitmap() public {
        PoolKey memory lying = key;
        // Claim the swap bit as well, which would let a hook tax every trade.
        lying.parameters = bytes32(uint256(hook.getHooksRegistrationBitmap() | uint16(1 << 6))).setBinStep(BIN_STEP);

        vm.expectRevert(Hooks.HookConfigValidationError.selector);
        poolManager.initialize(lying, ACTIVE_ID);
    }

    // ── the gate ──────────────────────────────────────────────────────────

    function test_allowlistedProviderCanMint() public {
        _mintVia(address(this), 1 ether);
        (uint128 reserveX, uint128 reserveY,,) = poolManager.getBin(poolId, ACTIVE_ID);
        assertGt(uint256(reserveX) + uint256(reserveY), 0, "allowlisted mint must land");
    }

    /// @dev A stranger taking the vault lock and calling the pool manager directly is refused.
    /// This is the test that passes even when the allowlist is armed wrongly - see the
    /// position-manager case below, which is why it is not on its own evidence of anything.
    function test_strangerCannotMint() public {
        BinLiquidityHelper rogue = new BinLiquidityHelper(poolManager, IVault(address(vault)));
        vm.startPrank(STRANGER);
        token0.approve(address(rogue), type(uint256).max);
        token1.approve(address(rogue), type(uint256).max);
        vm.stopPrank();

        IBinPoolManager.MintParams memory params = _getSingleBinMintParams(ACTIVE_ID, 1 ether, 1 ether);
        vm.prank(STRANGER);
        vm.expectRevert(); // bubbles up as Hooks.HookCallFailed around NotALiquidityProvider
        rogue.mint(key, params, "");
    }

    /// @dev Swapping is NOT gated, and that is the limit of what this hook buys. An outsider can
    /// still trade against the pool whenever its price is stale.
    function test_swapIsNotGated() public {
        _mintVia(address(this), 10 ether);

        uint256 before = token1.balanceOf(STRANGER);
        vm.prank(STRANGER);
        swapHelper.swap(key, true, -1 ether, BinSwapHelper.TestSettings(true, true), "");
        assertGt(token1.balanceOf(STRANGER), before, "a stranger must still be able to swap");
    }

    /// @dev Withdrawal is NOT gated, which is what makes the hook safe to live with: it cannot
    /// strand liquidity even after its owner has revoked the provider that deposited it.
    function test_burnIsNotGatedEvenAfterRevocation() public {
        _mintVia(address(this), 1 ether);

        vm.prank(TIMELOCK);
        hook.setLiquidityProvider(address(provider), false);

        BinPosition.Info memory position = poolManager.getPosition(poolId, address(provider), ACTIVE_ID, bytes32(0));
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = ACTIVE_ID;
        amounts[0] = position.share;

        uint256 before0 = token0.balanceOf(address(this));
        provider.burn(key, IBinPoolManager.BurnParams({ids: ids, amountsToBurn: amounts, salt: bytes32(0)}), "");

        assertEq(
            poolManager.getPosition(poolId, address(provider), ACTIVE_ID, bytes32(0)).share,
            0,
            "a revoked provider must still be able to exit"
        );
        assertGt(token0.balanceOf(address(this)), before0, "the exit must actually pay out");

        // ⚠️ NOT zero, and it never can be. `BinPool._addShare` burns MINIMUM_SHARE (1e3) off the
        // FIRST deposit into a bin and no position ever owns it, so a fully exited bin keeps a
        // dust reserve for ever. It matters beyond this assertion: a strategy that empties and
        // refills a bin pays that 1e3 again on every refill.
        (uint128 reserveX, uint128 reserveY,,) = poolManager.getBin(poolId, ACTIVE_ID);
        assertLe(uint256(reserveX) + uint256(reserveY), 2, "only the unowned MINIMUM_SHARE dust may remain");
    }

    // ── the way to arm it wrongly ─────────────────────────────────────────

    /// @dev 🔴 THE FAILURE MODE. `BinHooks.beforeMint` passes the `msg.sender` of
    /// `BinPoolManager.mint`, and `BinPositionManager` is what calls it when liquidity is added
    /// the ordinary way. Allowlist that address - the obvious thing to do if you want the LP UI
    /// to keep working - and every stranger reaches the pool through it. Note that
    /// `test_strangerCannotMint` above STILL PASSES in this configuration, so a suite without
    /// this case reports an armed gate on an open pool.
    function test_allowlistingThePositionManagerFailsOpen() public {
        vm.prank(TIMELOCK);
        hook.setLiquidityProvider(address(posm), true);

        int256[] memory deltaIds = new int256[](1);
        uint256[] memory distX = new uint256[](1);
        uint256[] memory distY = new uint256[](1);
        deltaIds[0] = 0;
        distX[0] = 1e18;
        distY[0] = 1e18;

        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.BIN_ADD_LIQUIDITY,
            abi.encode(
                IBinPositionManager.BinAddLiquidityParams({
                    poolKey: key,
                    amount0: 1 ether,
                    amount1: 1 ether,
                    amount0Max: 1 ether,
                    amount1Max: 1 ether,
                    activeIdDesired: ACTIVE_ID,
                    idSlippage: 0,
                    deltaIds: deltaIds,
                    distributionX: distX,
                    distributionY: distY,
                    minLiquidities: new uint256[](1),
                    to: STRANGER,
                    hookData: bytes("")
                })
            )
        );
        plan = plan.add(Actions.SETTLE_PAIR, abi.encode(key.currency0, key.currency1));

        vm.prank(STRANGER);
        posm.modifyLiquidities(plan.encode(), block.timestamp + 1);

        (uint128 reserveX, uint128 reserveY,,) = poolManager.getBin(poolId, ACTIVE_ID);
        assertGt(
            uint256(reserveX) + uint256(reserveY),
            0,
            "allowlisting the position manager lets an arbitrary stranger provide liquidity"
        );
    }

    // ── ownership ─────────────────────────────────────────────────────────

    function test_setLiquidityProviderIsOwnerOnly() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        vm.prank(STRANGER);
        hook.setLiquidityProvider(STRANGER, true);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(PermissionedLiquidityHook.ZeroAddress.selector);
        new PermissionedLiquidityHook(TIMELOCK, address(0));
    }
}
