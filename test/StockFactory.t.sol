// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";

import {IStockVaultExtension} from "../src/interfaces/IStockVaultExtension.sol";
import {StockFactory} from "../src/stock/StockFactory.sol";
import {StockRegistry} from "../src/stock/StockRegistry.sol";
import {StockVault} from "../src/stock/StockVault.sol";
import {StockConfig} from "../src/stock/StockTypes.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// The factory and the registry, on the harness's pool manager, price store, calendar, modules and
/// registry. The harness's own vault (hand-deployed, registered by the registry owner) is the first;
/// the factory adds vaults for further stock tokens under a second issuer.
contract StockFactoryTest is StockVaultHarness {
    using CLPoolParametersHelper for bytes32;

    address internal constant TIMELOCK = address(0x7111);
    address internal constant ISSUER2 = address(0x1552);

    StockFactory internal factory;
    MockERC20 internal stock2;
    MockERC20 internal stock3;

    function setUp() public override {
        super.setUp();
        factory = new StockFactory(
            OWNER,
            StockFactory.Parts({
                vaultCodeHash: keccak256(type(StockVault).creationCode),
                poolManager: manager,
                cash: IERC20(address(cash)),
                store: store,
                calendar: calendar,
                modules: sv.MODULES(),
                registry: registry,
                ratios: ratios,
                vaultOwner: TIMELOCK
            })
        );
        stock2 = new MockERC20("STOCK2", "S2", 18);
        stock3 = new MockERC20("STOCK3", "S3", 18);
        vm.startPrank(OWNER);
        registry.setFactory(address(factory));
        registry.setIssuerCap(ISSUER2, 60_000e6);
        vm.stopPrank();
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _listing(MockERC20 t) internal view returns (StockFactory.Listing memory) {
        return StockFactory.Listing({
            stock: IERC20(address(t)),
            issuer: ISSUER2,
            feedId: FEED,
            marketId: MARKET,
            name: "Stock vault 2",
            symbol: "SV2",
            fee: 3000,
            tickSpacing: 60,
            sqrtPriceX96: _sqrtAt(300)
        });
    }

    function _deploy(MockERC20 t, uint96 maxInventory) internal returns (address vault) {
        StockConfig memory c = _cfg();
        c.maxInventory = maxInventory;
        vm.prank(OWNER);
        vault = factory.deploy(type(StockVault).creationCode, _listing(t), c);
    }

    function _key(address vault, MockERC20 t) internal view returns (PoolKey memory) {
        (address c0, address c1) =
            address(cash) < address(t) ? (address(cash), address(t)) : (address(t), address(cash));
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(vault),
            poolManager: IPoolManager(address(manager)),
            fee: 3000,
            parameters: bytes32(uint256(sv.BITMAP())).setTickSpacing(60)
        });
    }

    // ── deployment ────────────────────────────────────────────────────────

    function test_aDeploymentIsRegisteredOpenedAndOffered() public {
        address vault = _deploy(stock2, 50_000e6);
        assertEq(registry.vaultOf(address(stock2)), vault);
        assertEq(registry.issuerOf(vault), ISSUER2);
        assertEq(registry.allocationOf(vault), 50_000e6);
        assertEq(registry.vaultCount(), 2);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(_key(vault, stock2).toId());
        assertEq(sqrtPriceX96, _sqrtAt(300), "the pool is open");

        StockVault v = StockVault(vault);
        assertEq(v.owner(), address(factory));
        assertEq(v.pendingOwner(), TIMELOCK);
        vm.prank(TIMELOCK);
        v.acceptOwnership();
        assertEq(v.owner(), TIMELOCK);
        assertEq(IStockVaultExtension(vault).registry(), address(registry));
        assertEq(IStockVaultExtension(vault).stock(), address(stock2));
    }

    function test_aFactoryVaultIsTheSameCodeAsAHandDeployment() public {
        address viaFactory = _deploy(stock2, 50_000e6);
        StockConfig memory c = _cfg();
        c.maxInventory = 50_000e6;
        StockVault byHand = new StockVault(
            StockVault.Init({
                cash: IERC20(address(cash)),
                stock: IERC20(address(stock2)),
                poolManager: manager,
                store: store,
                calendar: calendar,
                modules: sv.MODULES(),
                registry: address(registry),
                ratios: ratios,
                feedId: FEED,
                marketId: MARKET,
                owner: OWNER,
                name: "Stock vault 2",
                symbol: "SV2"
            }),
            c
        );
        assertEq(keccak256(viaFactory.code), keccak256(address(byHand).code));
    }

    function test_theFactoryRefusesOtherCode() public {
        bytes memory code = type(StockVault).creationCode;
        code[code.length - 1] ^= 0x01;
        vm.prank(OWNER);
        vm.expectRevert(StockFactory.WrongCode.selector);
        factory.deploy(code, _listing(stock2), _cfg());
    }

    function test_oneVaultPerStockToken() public {
        _deploy(stock2, 10_000e6);
        bytes memory code = type(StockVault).creationCode;
        StockFactory.Listing memory l = _listing(stock2);
        StockConfig memory c = _cfg();
        // A different config is different initcode, so CREATE2 lands elsewhere; the registry refuses it.
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.AlreadyRegistered.selector, address(stock2)));
        factory.deploy(code, l, c);
        // The same deployment twice collides at CREATE2.
        c.maxInventory = 10_000e6;
        vm.prank(OWNER);
        vm.expectRevert(StockFactory.DeployFailed.selector);
        factory.deploy(code, l, c);
    }

    function test_onlyTheOwnerDeploys() public {
        bytes memory code = type(StockVault).creationCode;
        StockFactory.Listing memory l = _listing(stock2);
        StockConfig memory c = _cfg();
        vm.prank(TRADER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, TRADER));
        factory.deploy(code, l, c);
    }

    // ── the issuer cap ────────────────────────────────────────────────────

    function test_anIssuersVaultsShareItsCap() public {
        address vault = _deploy(stock2, 50_000e6);
        bytes memory code = type(StockVault).creationCode;
        StockFactory.Listing memory l = _listing(stock3);
        StockConfig memory c = _cfg();
        c.maxInventory = 20_000e6;
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.OverIssuerCap.selector, 20_000e6, 10_000e6));
        factory.deploy(code, l, c);

        vm.prank(TIMELOCK);
        StockVault(vault).acceptOwnership();
        IStockVaultExtension v = IStockVaultExtension(vault);
        StockConfig memory raise = _cfg();
        raise.maxInventory = 70_000e6;
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.OverIssuerCap.selector, 70_000e6, 60_000e6));
        v.setConfig(raise);

        StockConfig memory lower = _cfg();
        lower.maxInventory = 30_000e6;
        vm.prank(TIMELOCK);
        v.setConfig(lower);
        assertEq(registry.room(ISSUER2), 30_000e6, "lowering frees room");
        _deploy(stock3, 20_000e6);
        assertEq(registry.room(ISSUER2), 10_000e6);
    }

    function test_onlyTheFactoryOrOwnerRegistersAndOnlyAVaultAllocates() public {
        vm.prank(TRADER);
        vm.expectRevert(StockRegistry.NotFactory.selector);
        registry.register(address(0xBEEF), address(stock2), ISSUER2, 1);
        vm.prank(TRADER);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.NotRegistered.selector, TRADER));
        registry.allocate(1);
        vm.prank(TRADER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, TRADER));
        registry.setIssuerCap(ISSUER2, 1);
    }
}
