// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";

import {BuybackBurnSink} from "../src/fees/BuybackBurnSink.sol";
import {IBurnableERC20} from "../src/interfaces/IBurnableERC20.sol";
import {InfinitySettler} from "../src/launchpad/InfinitySettler.sol";
import {BaseScript} from "./BaseScript.sol";

/**
 * The sprout.fun buyback-and-burn sink (SPROUT_TOKENOMICS §6, plan A4).
 *
 * Deploys `BuybackBurnSink` owned by the TIMELOCK from construction, then prints the calls that
 * still have to come from it. Nothing here wires anything: the sink's three settings are owner
 * calls and this script cannot make them.
 *
 * ⛔ It also never touches `ChoiceFeeController.setBurnSink`. Under D30 a Choice fee controller
 * is NEVER pointed at the sprout sink - sprout's revenue reaches it through the pad's treasury
 * and `PositionLocker.launchpadTreasury`, and the separation is the point.
 *
 * forge script script/09_DeployBuybackBurnSink.s.sol:DeployBuybackBurnSink -vv \
 *     --rpc-url $RPC_URL --broadcast
 *
 * No --slow: Injective never serves a receipt, so --slow strands the run after its first tx.
 * No --resume, ever. Re-run instead; every step below is idempotent.
 */
contract DeployBuybackBurnSink is BaseScript {
    /// 1.1.0 is plan A4: the normalise leg and the D32 hold allowlist. A launch token that is
    /// not SPROUT used to park for ever - which under D30/D31 is roughly half of a graduate's
    /// revenue, because a full-range position earns in both currencies.
    ///
    /// 🔴 No OTHER salt moves with it, and that is a claim worth stating rather than assuming.
    /// The rule that cost a graduation on 2026-09-06 is that a shared ABI needs both ends
    /// redeployed together; the only ABI this contract shares is `IBurnSink.burn`, which is
    /// byte-identical to 1.0.0's. Nothing calls `convert`, `setHold` or `setConversionTier`
    /// except a human and a keeper.
    bytes32 internal constant SINK_SALT = keccak256("CHOICE-V2/BuybackBurnSink/1.1.0");

    /// TEST values (§9.3). ⛔ Not mainnet's: the floor is immutable and one shot, and B2 puts it
    /// at 5000 with `burnBps` 7000. 8000/8000 is what the testnet sink it replaces carries, kept
    /// so the two are comparable.
    uint16 internal constant MIN_BURN_BPS = 8000;
    uint16 internal constant BURN_BPS = 8000;

    uint256 internal outstanding;

    function run() public {
        Create3Factory factory = Create3Factory(readAddress("governance.create3Factory"));
        address timelock = readAddress("governance.timelock");
        address treasury = readAddress("choice.treasury");
        address vault = readAddress("infinity.vault");
        address quote = readAddress("external.wINJ");
        address sprout = readAddress("launchpad.sproutToken");
        address settler = readAddress("choice.infinitySettler");

        requireCode("timelock", timelock);
        requireCode("vault", vault);
        requireCode("wINJ", quote);
        requireCode("sproutToken", sprout);
        requireCode("infinitySettler", settler);

        address sink = factory.computeAddress(SINK_SALT);
        console.log("BuybackBurnSink 1.1.0 ->", sink);

        if (sink.code.length == 0) {
            // 🔴 The hash the factory checks is of the WHOLE payload, constructor arguments
            // included - hashing the bare `creationCode` fails with `CreationCodeHashMismatch`.
            bytes memory payload = abi.encodePacked(
                type(BuybackBurnSink).creationCode,
                abi.encode(
                    IBurnableERC20(sprout),
                    Currency.wrap(quote),
                    IVault(vault),
                    treasury,
                    timelock,
                    MIN_BURN_BPS,
                    BURN_BPS
                )
            );

            vm.startBroadcast(deployerKey());
            address deployed = factory.deploy(SINK_SALT, payload, keccak256(payload), 0, "", 0);
            vm.stopBroadcast();
            require(deployed == sink, "create3 address prediction is wrong");
        } else {
            console.log("  already deployed - checking its wiring");
        }

        require(address(BuybackBurnSink(payable(sink)).BURN_TOKEN()) == sprout, "sink burns the wrong token");
        require(Currency.unwrap(BuybackBurnSink(payable(sink)).QUOTE()) == quote, "sink quotes the wrong currency");
        require(BuybackBurnSink(payable(sink)).owner() == timelock, "sink is not timelock-owned");

        writeAddress("choice.buybackBurnSink", sink);

        console.log("");
        console.log("What still has to happen. The sink PARKS everything until all three land,");
        console.log("so none of it is optional and none of it can brick a harvest either.");
        console.log("");

        _requireConversionTier(sink, settler);
        _requireGuards(sink);
        _requireBuybackPool(sink);

        console.log("");
        if (outstanding == 0) {
            console.log("  The sink is configured. It converts, buys back and burns.");
        } else {
            console.log(string.concat("  ", vm.toString(outstanding), " timelock step(s) OUTSTANDING - see above."));
            console.log("  Re-run this script after they land; it is idempotent and will confirm them.");
        }
    }

    /// @dev A4. The tier every graduation pool is keyed to, which is what lets the sink DERIVE a
    /// launch's pool instead of being registered one per launch.
    ///
    /// 🔴 Read off the settler rather than typed here. `hooks`, `lpFee` and `poolParameters`
    /// jointly ARE the non-currency half of a graduation pool key, and a tier that is one pip or
    /// one tick-spacing away from the settler's derives a key for a pool that does not exist -
    /// which parks silently, for ever, with nothing to look at.
    function _requireConversionTier(address sink, address settler) internal {
        address clPoolManager = readAddress("infinity.clPoolManager");
        IHooks hooks = InfinitySettler(settler).hooks();
        uint24 fee = InfinitySettler(settler).lpFee();
        bytes32 parameters = InfinitySettler(settler).poolParameters();

        (IPoolManager currentManager, IHooks currentHooks, uint24 currentFee, bytes32 currentParameters) =
            BuybackBurnSink(payable(sink)).conversionTier();
        if (
            address(currentManager) == clPoolManager && currentHooks == hooks && currentFee == fee
                && currentParameters == parameters
        ) {
            console.log("  [ok]   buybackBurnSink.conversionTier matches the settler");
            return;
        }
        outstanding++;
        console.log("  [TODO] the conversion tier does not match the settler's graduation pool");
        console.log("           hook", address(hooks));
        console.log("           lpFee", fee);
        _printTimelockPayloads(
            sink,
            abi.encodeCall(BuybackBurnSink.setConversionTier, (IPoolManager(clPoolManager), hooks, fee, parameters))
        );
    }

    /// @dev Until `setGuards` is called `maxImpactBps` is 0, which truncates to a price limit the
    /// pool refuses - so every swap parks. `minBuybackInterval` of 0 is refused outright.
    function _requireGuards(address sink) internal {
        if (BuybackBurnSink(payable(sink)).maxImpactBps() != 0) {
            console.log("  [ok]   buybackBurnSink.setGuards");
            return;
        }
        outstanding++;
        console.log("  [TODO] the guards are unset, so every buyback and every conversion parks");
        console.log("           TEST values below - see SPROUT_TOKENOMICS 9.3 before mainnet");
        _printTimelockPayloads(sink, abi.encodeCall(BuybackBurnSink.setGuards, (1e15, 500, 60)));
    }

    /// @dev The one pool the sink cannot derive: SPROUT's own graduation pool is where the
    /// buyback spends, and SPROUT is a launch like any other, so the key is built the same way
    /// and then checked against the chain.
    function _requireBuybackPool(address sink) internal {
        BuybackBurnSink s = BuybackBurnSink(payable(sink));
        (,,, IPoolManager installed,,) = s.buybackPool();
        if (address(installed) != address(0)) {
            console.log("  [ok]   buybackBurnSink.setBuybackPool");
            return;
        }

        (PoolKey memory key,) = s.conversionPool(Currency.wrap(address(s.BURN_TOKEN())));
        if (address(key.poolManager) == address(0)) {
            console.log("  [--]   buybackPool: set the conversion tier first, it derives this key");
            outstanding++;
            return;
        }
        (uint160 existing,,,) = ICLPoolManager(address(key.poolManager)).getSlot0(key.toId());
        if (existing == 0) {
            outstanding++;
            console.log("  [TODO] SPROUT's graduation pool does not exist yet - it has not graduated");
            return;
        }
        outstanding++;
        console.log("  [TODO] the buyback pool is unset, so quote revenue parks");
        _printTimelockPayloads(sink, abi.encodeCall(BuybackBurnSink.setBuybackPool, (key)));
    }

    /// @dev Both halves, because matching `execute`'s arguments to the `schedule` they came
    /// from is the whole trick with a `TimelockController`.
    function _printTimelockPayloads(address target, bytes memory payload) internal view {
        uint256 delay = readUint("governance.timelockMinDelay");
        console.log(
            string.concat(
                "           1. Safe -> timelock.schedule: ",
                vm.toString(
                    abi.encodeWithSignature(
                        "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
                        target,
                        uint256(0),
                        payload,
                        bytes32(0),
                        bytes32(0),
                        delay
                    )
                )
            )
        );
        console.log(
            string.concat(
                "           2. after ",
                vm.toString(delay),
                "s, anyone -> timelock.execute: ",
                vm.toString(
                    abi.encodeWithSignature(
                        "execute(address,uint256,bytes,bytes32,bytes32)",
                        target,
                        uint256(0),
                        payload,
                        bytes32(0),
                        bytes32(0)
                    )
                )
            )
        );
    }
}
