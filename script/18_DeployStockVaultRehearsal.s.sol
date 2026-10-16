// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {IPriceStore} from "../src/interfaces/IPriceStore.sol";
import {MarketCalendar} from "../src/stock/MarketCalendar.sol";
import {OraclePriceStore} from "../src/stock/OraclePriceStore.sol";
import {StockAdmin} from "../src/stock/StockAdmin.sol";
import {StockFactory} from "../src/stock/StockFactory.sol";
import {StockPublic} from "../src/stock/StockPublic.sol";
import {StockRatios} from "../src/stock/StockRatios.sol";
import {StockRegistry} from "../src/stock/StockRegistry.sol";
import {StockVault} from "../src/stock/StockVault.sol";
import {StockConfig} from "../src/stock/StockTypes.sol";
import {BaseScript} from "./BaseScript.sol";

/**
 * Stock vault MAINNET REHEARSAL at test caps: one AAPL vault, owned by the operator EOA (no Safe, no
 * timelock), issued by the live issuer, priced by an `OraclePriceStore` pinned to Pyth's signer.
 *
 * 🔴 It does NOT deploy the vault itself. The vault's constructor calls `decimals()` on the stock
 * token, an MTS bank ERC20 backed by the 0x64 precompile, which a forge script's local EVM cannot
 * execute. So this script deploys every part that does not touch the stock (store, calendar,
 * registry, ratios, modules, factory), wires the registry to the factory, and WRITES the factory's
 * `deploy(...)` calldata to `$OUT_DIR/deploy_calldata.hex`, built from this run's linked vault
 * creation code (whose hash the factory pins). The driver then sends that calldata with
 * `cast send`, so the constructor runs on chain, and makes the owner calls the vault needs.
 *
 * Addresses go to `$OUT_DIR/rehearsal.json`, NOT the address book: a rehearsal is torn down.
 *
 *   NETWORK=injective_mainnet OUT_DIR=<dir> OPERATOR=<addr> \
 *     with-key.sh <key> forge script script/18_DeployStockVaultRehearsal.s.sol \
 *       --rpc-url $RPC --broadcast --private-key $PRIVATE_KEY --gas-estimate-multiplier 400
 */
contract DeployStockVaultRehearsal is BaseScript {
    // Pyth Pro's signer as the Lazer verifier on 1776 has it (see test/fixtures/LazerFixtures.sol).
    address internal constant PYTH_SIGNER = 0x26FB61A864c758AE9fBA027a96010480658385B9;
    uint64 internal constant SIGNER_EXPIRY = 2_077_357_410;
    uint32 internal constant RELAY_LAG_MS = 1000;

    // The live issuer and its AAPL token; Pyth feed 922; the Helix AAPL/USDC perp.
    address internal constant ISSUER = 0x74a548ecdCa848654314402D9f8Fb19214A5008c;
    address internal constant AAPLS = 0xeBaf9Cd753F76C79aa47a910254D476B04d4a35A;
    uint32 internal constant FEED = 922;
    string internal constant MARKET = "0xa3d0ef8d845ada306a53baabd04edab9c5525ba9e011648a09aa064db5ca3442";

    uint256 internal constant START_PRICE_USD = 345;

    function run() external {
        address operator = vm.envAddress("OPERATOR");
        string memory outDir = vm.envString("OUT_DIR");
        address usdc = readAddress("external.usdc");
        ICLPoolManager manager = ICLPoolManager(readAddress("infinity.clPoolManager"));

        vm.startBroadcast();
        OraclePriceStore store = new OraclePriceStore(operator, PYTH_SIGNER, SIGNER_EXPIRY, RELAY_LAG_MS);
        MarketCalendar calendar = new MarketCalendar(operator, operator);
        _holidays(calendar);
        StockRegistry registry = new StockRegistry(operator);
        StockRatios ratios = new StockRatios(operator, operator);
        address modules = address(new StockPublic(address(new StockAdmin())));
        bytes memory code = type(StockVault).creationCode;
        StockFactory factory = new StockFactory(
            operator,
            StockFactory.Parts({
                vaultCodeHash: keccak256(code),
                poolManager: manager,
                cash: IERC20(usdc),
                cashDenom: string.concat("erc20:", vm.toString(usdc)),
                store: IPriceStore(address(store)),
                calendar: calendar,
                modules: modules,
                registry: registry,
                ratios: ratios,
                vaultOwner: operator
            })
        );
        registry.setFactory(address(factory));
        registry.setIssuerCap(ISSUER, 1_000e6);
        vm.stopBroadcast();

        StockFactory.Listing memory listing = StockFactory.Listing({
            stock: IERC20(AAPLS),
            issuer: ISSUER,
            feedId: FEED,
            marketId: MARKET,
            name: "Choice AAPL vault (rehearsal)",
            symbol: "cvAAPL-r",
            fee: 3000,
            tickSpacing: 60,
            sqrtPriceX96: _sqrtAt(usdc, START_PRICE_USD)
        });
        vm.writeFile(
            string.concat(outDir, "/deploy_calldata.hex"),
            vm.toString(abi.encodeCall(StockFactory.deploy, (code, listing, config())))
        );

        string memory j = "rehearsal";
        vm.serializeAddress(j, "store", address(store));
        vm.serializeAddress(j, "calendar", address(calendar));
        vm.serializeAddress(j, "registry", address(registry));
        vm.serializeAddress(j, "ratios", address(ratios));
        vm.serializeAddress(j, "modules", modules);
        vm.serializeAddress(j, "poolManager", address(manager));
        vm.serializeAddress(j, "usdc", usdc);
        vm.serializeAddress(j, "stock", AAPLS);
        vm.serializeAddress(j, "issuer", ISSUER);
        vm.serializeAddress(j, "operator", operator);
        vm.serializeBytes32(j, "vaultCodeHash", keccak256(code));
        string memory out = vm.serializeAddress(j, "factory", address(factory));
        vm.writeJson(out, string.concat(outDir, "/rehearsal.json"));
    }

    /// @notice Test caps: $100 of deposits, $50 of stock, $20 a trade, a 2x hedge.
    function config() public pure returns (StockConfig memory) {
        return StockConfig({
            spreadRegular: 25,
            spreadExtended: 40,
            spreadOvernight: 50,
            spreadClosed: 80,
            minSpread: 10,
            maxSpread: 200,
            agePerSecondBps: 0,
            quoteMissingBps: 0,
            confidenceMissingBps: 0,
            sizeBps: 0,
            windowBps: 0,
            skewBps: 0,
            openBps: 0,
            reanchorBps: 30,
            maxJumpBps: 1500,
            hedgeSlippageBps: 60,
            leverageX10: 20,
            navJumpBps: 500,
            restockSlippageBps: 100,
            maxAgeMs: 3000,
            closeTolerance: 300,
            openWindow: 900,
            reanchorDelay: 300,
            reanchorWide: 900,
            window: 3600,
            publicHedgeDelay: 300,
            restockDeadline: 3600,
            restockExpiryUnit: 1 hours,
            makerTimeout: 600,
            queueDeadline: 1 days,
            exitFeeBps: 0,
            weekendFills: false,
            overnightLive: true,
            maxTrade: 20e6,
            maxTradeClosed: 5e6,
            windowCap: 100e6,
            windowCapClosed: 10e6,
            maxInventory: 50e6,
            targetInventory: 0,
            maxUnhedged: 10e6,
            hedgeBand: 2e6,
            minHedge: 1e6,
            cashReserve: 0,
            tvlCap: 100e6,
            restockDailyCap: 50e6,
            minRedeem: 1e6,
            qtyTick: 1e15,
            priceTick: 1e16,
            depositLock: 5 minutes
        });
    }

    /// @dev NYSE closures and half days through the rehearsal's horizon (days since 1970).
    function _holidays(MarketCalendar calendar) internal {
        uint32[] memory closed = new uint32[](2);
        closed[0] = _day(2026, 11, 26); // Thanksgiving
        closed[1] = _day(2026, 12, 25); // Christmas
        calendar.setDays(closed, MarketCalendar.DayType.Closed);
        uint32[] memory half = new uint32[](2);
        half[0] = _day(2026, 11, 27);
        half[1] = _day(2026, 12, 24);
        calendar.setDays(half, MarketCalendar.DayType.Half);
    }

    /// @dev Days from 1970-01-01 to y-m-d (proleptic Gregorian).
    function _day(uint256 y, uint256 m, uint256 d) internal pure returns (uint32) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return uint32(era * 146_097 + doe - 719_468);
    }

    /// @dev The pool's price at `usd` per stock: currency1 per currency0 in raw units, as sqrt Q96.
    function _sqrtAt(address usdc, uint256 usd) internal pure returns (uint160) {
        bool cashIs0 = usdc < AAPLS;
        uint256 priceX192 = cashIs0 ? (uint256(1e18) << 192) / (usd * 1e6) : (usd * 1e6 << 192) / 1e18;
        return uint160(Math.sqrt(priceX192));
    }
}
