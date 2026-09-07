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

import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

import {BuybackBurnSink} from "../src/fees/BuybackBurnSink.sol";
import {IBurnableERC20} from "../src/interfaces/IBurnableERC20.sol";
import {ILaunchPositionLocker} from "../src/interfaces/ILaunchPositionLocker.sol";
import {BaseScript} from "./BaseScript.sol";

/**
 * The launchpad's buyback-and-burn sink (plan A4).
 *
 * Deploys `BuybackBurnSink` owned by the TIMELOCK from construction, then prints the calls that
 * still have to come from it. Nothing here wires anything: the sink's three settings are owner
 * calls and this script cannot make them.
 *
 * ⛔ It also never touches `ChoiceFeeController.setBurnSink`. Under D30 a Choice fee controller
 * is NEVER pointed at this sink - the launchpad's revenue reaches it through the pad's treasury
 * and `PositionLocker.launchpadTreasury`, and the separation is the point.
 *
 * forge script script/09_DeployBuybackBurnSink.s.sol:DeployBuybackBurnSink -vv \
 *     --rpc-url $RPC_URL --broadcast
 *
 * No --slow: Injective never serves a receipt, so --slow strands the run after its first tx.
 * No --resume, ever. Re-run instead; every step below is idempotent.
 */
contract DeployBuybackBurnSink is BaseScript {
    /// 1.2.0 is plan A5: the sink ASKS a launch's locked position for its real pool key instead
    /// of deriving one from a stored tier. `setConversionTier` is gone, and with it the straggler
    /// case - a launch that graduated on an earlier fee tier stopped being derivable, silently,
    /// and its revenue parked until somebody pointed the tier back.
    ///
    /// 🔴 **A salt DOES move with this one.** `LaunchFeeCranker` (script 10) calls
    /// `convert(Currency,uint256)`, which exists only from 1.2.0, and it holds its sink as an
    /// immutable - so a sink redeploy is always a cranker redeploy. That is the A3 rule applied
    /// forwards for once rather than discovered afterwards: bump both, deploy both, and check
    /// `cranker.SINK()` afterwards.
    ///
    /// ⚠️ It also needs the timelock to `setLockers` before any launch token can convert, and to
    /// repoint `PositionLocker.launchpadTreasury` at the new address on EVERY live locker - the
    /// old sink keeps whatever is parked in it until it is swept.
    bytes32 internal constant SINK_SALT = keccak256("CHOICE-V2/BuybackBurnSink/1.3.0");

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
        address burnToken = readAddress("launchpad.burnToken");
        address positionManager = readAddress("infinity.clPositionManager");

        requireCode("timelock", timelock);
        requireCode("vault", vault);
        requireCode("wINJ", quote);
        requireCode("burnToken", burnToken);
        requireCode("clPositionManager", positionManager);

        address sink = factory.computeAddress(SINK_SALT);
        console.log("BuybackBurnSink 1.2.0 ->", sink);

        if (sink.code.length == 0) {
            // 🔴 The hash the factory checks is of the WHOLE payload, constructor arguments
            // included - hashing the bare `creationCode` fails with `CreationCodeHashMismatch`.
            bytes memory payload = abi.encodePacked(
                type(BuybackBurnSink).creationCode,
                abi.encode(
                    IBurnableERC20(burnToken),
                    Currency.wrap(quote),
                    IVault(vault),
                    ICLPositionManager(positionManager),
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

        require(address(BuybackBurnSink(payable(sink)).BURN_TOKEN()) == burnToken, "sink burns the wrong token");
        require(Currency.unwrap(BuybackBurnSink(payable(sink)).QUOTE()) == quote, "sink quotes the wrong currency");
        require(BuybackBurnSink(payable(sink)).owner() == timelock, "sink is not timelock-owned");

        writeAddress("choice.buybackBurnSink", sink);

        console.log("");
        console.log("What still has to happen. The sink PARKS everything until all three land,");
        console.log("so none of it is optional and none of it can brick a harvest either.");
        console.log("");

        _requireLockers(sink);
        _requireGuards(sink);
        _requireBuybackPool(sink);
        _reportQuoteRoutes(sink);

        console.log("");
        if (outstanding == 0) {
            console.log("  The sink is configured. It converts, buys back and burns.");
        } else {
            console.log(string.concat("  ", vm.toString(outstanding), " timelock step(s) OUTSTANDING - see above."));
            console.log("  Re-run this script after they land; it is idempotent and will confirm them.");
        }
    }

    /// @dev A5. The position lockers a conversion may read a graduate's pool key out of.
    ///
    /// 🔴 This replaces `_requireConversionTier`, and the replacement is the point of A5. That
    /// one read `hooks()`, `lpFee()` and `poolParameters()` off the settler and asked the sink to
    /// carry a copy - a FIFTH copy of "which settler is current", after the keeper's
    /// `PHASE3_SETTLER`, the pad backend's `CHOICE_V2_SETTLERS`, the pad frontend's
    /// `ADDRESSES.infinitySettlers` and this repo's own `verify-all.sh`. All four of the others
    /// were found stale on the same day, two of them meaning no graduate was tradable in the pad
    /// UI with nothing failing. The sink does not hold a copy any more; it asks a locker.
    ///
    /// ⚠️ The list is EVERY locker whose launches should stay convertible, not just the live one.
    /// Testnet has two generations and the older one holds launches 13-17.
    function _requireLockers(address sink) internal {
        address[] memory wanted = _wantedLockers();

        address[] memory installed = BuybackBurnSink(payable(sink)).lockers();
        bool matches = installed.length == wanted.length;
        for (uint256 i; matches && i < wanted.length; ++i) {
            if (installed[i] != wanted[i]) matches = false;
        }
        if (matches) {
            console.log("  [ok]   buybackBurnSink.setLockers");
            return;
        }

        outstanding++;
        console.log("  [TODO] the locker set does not match the address book");
        for (uint256 i; i < wanted.length; ++i) {
            console.log("           want", wanted[i]);
        }
        _printTimelockPayloads(sink, abi.encodeCall(BuybackBurnSink.setLockers, (wanted)));
    }

    /// @dev A2/D28. Which quote assets can currently reach `QUOTE`, and which cannot.
    ///
    /// A launch paired against an asset with no registered route collects and claims exactly as
    /// it should, and the sink then refuses BOTH halves of its fee - the launch token by name,
    /// and the pair asset because nothing knows where to sell it. Neither is stranded and neither
    /// is silent, but neither burns either, so this belongs on the same list as the other three.
    ///
    /// ⚠️ It REPORTS rather than requiring, deliberately. A route names an ordinary pool that
    /// nobody's settler opened, so there is nothing on chain for this script to derive it from
    /// and nothing safe to guess - which is the whole reason the route is registered in the first
    /// place. `choice.quoteRouteAssetKeys` in the address book is the operator's list of assets
    /// that SHOULD have one; the pool key itself is supplied when the timelock call is made.
    ///
    /// 🔑 It holds BOOK KEYS (`"external.sai"`), not addresses. CI refuses a book in which one
    /// address appears under two keys, and rightly: an address written twice is an address that
    /// can be updated once.
    function _reportQuoteRoutes(address sink) internal view {
        address[] memory assets = readAddressesByKeyList("choice.quoteRouteAssetKeys");
        if (assets.length == 0) {
            console.log("  [note] no quoteRouteAssetKeys in the address book.");
            console.log("           A launch paired against anything but QUOTE will park both halves");
            console.log("           of its LP fee until setQuoteRoute names a pool. See plan A2/D28.");
            return;
        }
        for (uint256 i; i < assets.length; ++i) {
            (,, bool found) = BuybackBurnSink(payable(sink)).quoteRoute(Currency.wrap(assets[i]));
            console.log(found ? "  [ok]   quote route" : "  [TODO] quote route MISSING for", assets[i]);
        }
    }

    /// @dev The live locker, plus any superseded one still holding graduated positions.
    /// `positionLockerLegacy` is optional: a fresh deployment has none.
    function _wantedLockers() internal view returns (address[] memory wanted) {
        address live = readAddress("choice.positionLocker");
        address legacy = readAddressOrZero("choice.positionLockerLegacy");
        requireCode("positionLocker", live);

        wanted = new address[](legacy == address(0) ? 1 : 2);
        wanted[0] = live;
        if (legacy != address(0)) {
            requireCode("positionLockerLegacy", legacy);
            wanted[1] = legacy;
        }
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
        console.log("           TEST values below - see the launchpad tokenomics before mainnet");
        _printTimelockPayloads(sink, abi.encodeCall(BuybackBurnSink.setGuards, (1e15, 500, 60)));
    }

    /// @dev The one pool the sink cannot be told about by a caller: the buyback's own.
    ///
    /// The burn token is a launch like any other, so its graduation pool key is read the same way
    /// every other launch's is now - off its own locked position, through `launchPool`. That is
    /// strictly better than the tier derivation it replaces: it is the key the position is
    /// actually in, so it cannot be one fee tier or one tick spacing away from a pool that does
    /// not exist.
    ///
    /// ⚠️ Needs `launchpad.burnTokenLaunchId` in the address book, and the lockers installed first -
    /// which is why this check runs last.
    function _requireBuybackPool(address sink) internal {
        BuybackBurnSink s = BuybackBurnSink(payable(sink));
        (,,, IPoolManager installed,,) = s.buybackPool();
        if (address(installed) != address(0)) {
            console.log("  [ok]   buybackBurnSink.setBuybackPool");
            return;
        }

        outstanding++;
        uint256 burnTokenLaunchId = readUint("launchpad.burnTokenLaunchId");
        (PoolKey memory key, address locker) = s.launchPool(burnTokenLaunchId);
        if (locker == address(0)) {
            console.log("  [--]   buybackPool: install the lockers first, they answer this key");
            return;
        }
        (uint160 existing,,,) = ICLPoolManager(address(key.poolManager)).getSlot0(key.toId());
        if (existing == 0) {
            console.log("  [TODO] the burn token's pool does not exist yet - it has not graduated");
            return;
        }
        console.log("  [TODO] the buyback pool is unset, so quote revenue parks");
        console.log("           read off the burn token's locked position, launch", burnTokenLaunchId);
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
