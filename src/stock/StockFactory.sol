// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";

import {IPriceStore} from "../interfaces/IPriceStore.sol";
import {MarketCalendar} from "./MarketCalendar.sol";
import {IStockRatios} from "../interfaces/IStockRatios.sol";
import {StockRegistry} from "./StockRegistry.sol";
import {StockVault} from "./StockVault.sol";
import {StockConfig} from "./StockTypes.sol";

/// @title StockFactory
/// @notice Deploys every stock vault of a deployment from the same code and the same parts, registers
/// it, opens its pool and hands it to its owner.
///
/// **The same code.** The vault's creation code (about 28 KB) cannot sit inside a contract's runtime,
/// so the owner passes it with each deployment and the factory refuses any whose hash is not
/// `VAULT_CODE_HASH`. The libraries are linked into that code, so the hash pins them too; the modules,
/// the price store, the calendar, the registry, the ratio registry, the pool manager and the cash token
/// are pinned here.
/// What varies per vault is the stock token, its issuer, its feed and perp market, its names, its
/// config and its pool's fee, spacing and starting price.
///
/// **One vault per stock token.** The registry refuses a second vault for a token. (The CREATE2 salt
/// is the token too, so the same deployment twice collides; a different config is different initcode
/// and would land elsewhere, which is why the registry is the guard.)
///
/// **Ownership.** A vault is created owned by this factory, which opens its pool (only a vault's owner
/// may) and then offers ownership to `VAULT_OWNER` (Ownable2Step), which must accept. The factory has
/// nothing else it can do with a vault in between.
contract StockFactory is Ownable2Step {
    using CLPoolParametersHelper for bytes32;

    struct Parts {
        bytes32 vaultCodeHash;
        ICLPoolManager poolManager;
        IERC20 cash;
        string cashDenom;
        uint32 cashFeedId;
        IPriceStore store;
        MarketCalendar calendar;
        address modules;
        StockRegistry registry;
        IStockRatios ratios;
        address vaultOwner;
    }

    struct Listing {
        IERC20 stock;
        address issuer;
        uint32 feedId;
        string marketId;
        string name;
        string symbol;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
    }

    bytes32 public immutable VAULT_CODE_HASH;
    ICLPoolManager public immutable POOL_MANAGER;
    IERC20 public immutable CASH;
    /// @notice The cash's own USD feed, which every vault prices the stock through. See `StockLib.inCash`.
    uint32 public immutable CASH_FEED_ID;
    IPriceStore public immutable PRICE_STORE;
    MarketCalendar public immutable CALENDAR;
    address public immutable MODULES;
    StockRegistry public immutable REGISTRY;
    IStockRatios public immutable RATIOS;
    address public immutable VAULT_OWNER;
    /// @notice The cash's bank denom, which every vault's hedge subaccount is funded in.
    string public cashDenom;

    error WrongCode();
    error DeployFailed();
    error ZeroAddress();

    event VaultDeployed(address indexed vault, address indexed stock, address indexed issuer, PoolId poolId);

    constructor(address owner_, Parts memory p) Ownable(owner_) {
        if (
            p.vaultCodeHash == bytes32(0) || address(p.poolManager) == address(0) || address(p.cash) == address(0)
                || address(p.store) == address(0) || address(p.calendar) == address(0) || p.modules == address(0)
                || address(p.registry) == address(0) || p.vaultOwner == address(0) || bytes(p.cashDenom).length == 0
        ) revert ZeroAddress();
        cashDenom = p.cashDenom;
        VAULT_CODE_HASH = p.vaultCodeHash;
        POOL_MANAGER = p.poolManager;
        CASH = p.cash;
        CASH_FEED_ID = p.cashFeedId;
        PRICE_STORE = p.store;
        CALENDAR = p.calendar;
        MODULES = p.modules;
        REGISTRY = p.registry;
        RATIOS = p.ratios;
        VAULT_OWNER = p.vaultOwner;
    }

    /// @notice Deploy the vault for `x.stock` from `creationCode`, register it at its inventory cap,
    /// open its pool and offer it to `VAULT_OWNER`.
    function deploy(bytes calldata creationCode, Listing calldata x, StockConfig calldata config)
        external
        onlyOwner
        returns (address vault)
    {
        if (keccak256(creationCode) != VAULT_CODE_HASH) revert WrongCode();
        StockVault.Init memory init = StockVault.Init({
            cash: CASH,
            stock: x.stock,
            poolManager: POOL_MANAGER,
            store: PRICE_STORE,
            calendar: CALENDAR,
            modules: MODULES,
            registry: address(REGISTRY),
            ratios: RATIOS,
            feedId: x.feedId,
            cashFeedId: CASH_FEED_ID,
            marketId: x.marketId,
            cashDenom: cashDenom,
            owner: address(this),
            name: x.name,
            symbol: x.symbol
        });
        bytes memory initcode = abi.encodePacked(creationCode, abi.encode(init, config));
        bytes32 salt = keccak256(abi.encode(x.stock));
        assembly ("memory-safe") {
            vault := create2(0, add(initcode, 0x20), mload(initcode), salt)
        }
        if (vault == address(0)) revert DeployFailed();

        REGISTRY.register(vault, address(x.stock), x.issuer, config.maxInventory);
        (address c0, address c1) =
            address(CASH) < address(x.stock) ? (address(CASH), address(x.stock)) : (address(x.stock), address(CASH));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(vault),
            poolManager: IPoolManager(address(POOL_MANAGER)),
            fee: x.fee,
            parameters: bytes32(uint256(StockVault(vault).BITMAP())).setTickSpacing(x.tickSpacing)
        });
        POOL_MANAGER.initialize(key, x.sqrtPriceX96);
        StockVault(vault).transferOwnership(VAULT_OWNER);
        emit VaultDeployed(vault, address(x.stock), x.issuer, key.toId());
    }
}
