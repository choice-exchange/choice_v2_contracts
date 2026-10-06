// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IBuybackBurnSink} from "../src/interfaces/IBuybackBurnSink.sol";
import {IBurnableERC20} from "../src/interfaces/IBurnableERC20.sol";
import {BaseScript} from "./BaseScript.sol";

/**
 * The launchpad's buyback-and-burn sink (plan A4).
 *
 * Deploys `BuybackBurnSink` owned by the TIMELOCK from construction, then reports what still has
 * to come from it. Nothing here wires anything: the sink's settings are owner calls and this
 * script cannot make them. Since 1.8.0 the turn-on settings are ONE timelock batch, built by
 * `script/15` (the 2026-10-01 audit's F3). This script reports them and never prints them one
 * operation at a time.
 *
 * 🔴 It does not import the sink's SOURCE, only `IBuybackBurnSink`, and it takes the creation
 * code from the sink's artifact with `vm.getCode`. The sink compiles under its own optimizer
 * profile (`foundry.toml`), and a file that imported it would be compiled under that profile too.
 * For script 13, which inherits this one, that would also rebuild the CRANKER's embedded creation
 * code at 1,000 runs.
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
    /// 🔴 **A sink redeploy is NO LONGER a cranker redeploy.** This used to say it was, because
    /// `LaunchFeeCranker` held its sink as an immutable - true of 1.x, and false since **2.0.0**,
    /// which makes `SINK` ordinary storage behind an `onlyOwner` `setSink` precisely so that a
    /// sink bump costs one timelock call instead of a contract. Checked against the deployed
    /// testnet cranker `0x8454d702…` (2.0.0): `setSink(address)` exists and reverts
    /// `OwnableUnauthorizedAccount` to an unprivileged caller. Point the existing cranker at the
    /// new sink and check `cranker.SINK()` afterwards; deploy a new one only if the LOCKER moved,
    /// which `LOCKER` being immutable still forces.
    ///
    /// ⚠️ It also needs the timelock to `setLockers` before any launch token can convert, and to
    /// repoint `PositionLocker.launchpadTreasury` at the new address on EVERY live locker - the
    /// old sink keeps whatever is parked in it until it is swept.
    ///
    /// 1.4.0 carried plan **B2's numbers** rather than testnet's legacy pair - see below.
    /// 1.5.0 added DERIVED quote hops, and that was a HIGH-severity hole: the search took the
    /// deepest initialised HOOKLESS `{asset, QUOTE}` pool, which is precisely the pool anybody
    /// can open at a price of their choosing. 1.6.0 removes derivation - `setQuoteRoute` is the
    /// only source of a hop again.
    ///
    /// ⛔ **THE SALT STILL SAYS 1.5.0, AND THAT IS ON PURPOSE. DO NOT "FIX" IT.** A CREATE3
    /// salt is an ADDRESS, not a version string. On mainnet this one computes
    /// `0x65Dc46Ee554A27bC790710f9fAee74B427c1C57D`, which is already
    /// `LaunchPoolFeeHook.treasury()` AND `PositionLocker.launchpadTreasury()`, and which already
    /// holds accrued wINJ that only code deployed at this salt can ever move. Bumping the string
    /// would move the address, add two repoint calls to the timelock batch, and strand that
    /// balance behind a second batch and a rescue contract. The version lives in the contract's
    /// VERSION line instead. On TESTNET this salt is already spent by the real 1.5.0, so the
    /// fixed sink rehearses there under script 13's `CHOICE-V2-REHEARSAL/` salt, as it already
    /// did. Decided with Dan, 2026-09-16.
    bytes32 internal constant SINK_SALT = keccak256("CHOICE-V2/BuybackBurnSink/1.5.0");

    /// 🎯 **B2's values, and they are now the same on both networks — deliberately.** The floor is
    /// immutable and one shot, so the single figure in the whole plan that must be right first
    /// time had never been executed anywhere: every deployed sink carries 8000/8000, and on an
    /// 8000 floor `setBurnBps(5000)` reverts. That made the plan's own Done-when 6 - *the floor
    /// shipped at 5000, proven by `setBurnBps(5000)` succeeding and `setBurnBps(4999)` reverting* -
    /// checkable ONLY on mainnet, i.e. only after it was irreversible.
    ///
    /// Deploying the rehearsal sink at 5000/7000 is what makes it checkable beforehand. ⚠️ It
    /// costs comparability with the 2026-09-06 walk's burn figures, which were measured at 8000:
    /// a burn under this sink destroys 7000 bps of the bought-back amount, not 8000, so do not
    /// diff the two runs' totals without scaling.
    ///
    /// 🔴 `BURN_BPS` is 8000 since Dan's 2026-10-03 decision: 80% of the launchpad's protocol
    /// revenue buys the burn token, as the launchpad now says publicly. Under sink 1.8.0 it is the
    /// share of REVENUE that buys and burns. The other 20% is paid to the treasury in wINJ.
    uint16 internal constant MIN_BURN_BPS = 5000;
    uint16 internal constant BURN_BPS = 8000;

    /// The turn-on settings `script/15` schedules as one batch. They live here so that this
    /// script's report and that batch can never disagree.
    ///
    /// - `MIN_BUYBACK` 0.5 wINJ: below it a swap costs more in gas than it moves.
    /// - `MAX_IMPACT_BPS` 100: an upper bound only. The per-leg fee cap binds first: 0.3% of price
    ///   on the burn token's 1% fee-hook pool with a 7000 creator share.
    /// - `MIN_INTERVAL` 300 s: one fill per window, on the operator path and the public one alike
    ///   (1.8.0). The keeper's `BUYBACK_INTERVAL_MS` default is the same five minutes.
    /// - `MAX_BUYBACK` 10 wINJ: about one fee-capped fill on the mainnet burn pool (~6,690 wINJ
    ///   deep on 2026-10-06), so it costs no throughput. A pump-and-JIT sandwich pays only when
    ///   the tranche is over `fee * depth`: ~67 wINJ for an outsider there, ~20 for whoever holds
    ///   the burn token's creator key. Anchored sizing closes the attack on its own. This is the second
    ///   bound.
    /// - `FALLBACK_DELAY` 6 h of operator silence before the public path reopens.
    uint256 internal constant MIN_BUYBACK = 0.5e18;
    uint16 internal constant MAX_IMPACT_BPS = 100;
    uint32 internal constant MIN_INTERVAL = 300;
    uint256 internal constant MAX_BUYBACK = 10e18;
    uint32 internal constant FALLBACK_DELAY = 6 hours;

    uint256 internal outstanding;

    function run() public virtual {
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
        console.log("BuybackBurnSink 1.8.0 (salt 1.5.0) ->", sink);

        if (sink.code.length == 0) {
            bytes memory payload = _sinkPayload(burnToken, quote, vault, positionManager, treasury, timelock);

            requireWhitelistedDeployer(address(factory));
            vm.startBroadcast(deployerKey());
            address deployed = factory.deploy(SINK_SALT, payload, keccak256(payload), 0, "", 0);
            vm.stopBroadcast();
            require(deployed == sink, "create3 address prediction is wrong");
        } else {
            console.log("  already deployed - checking its wiring");
        }

        require(address(IBuybackBurnSink(sink).BURN_TOKEN()) == burnToken, "sink burns the wrong token");
        require(Currency.unwrap(IBuybackBurnSink(sink).QUOTE()) == quote, "sink quotes the wrong currency");
        require(Ownable(sink).owner() == timelock, "sink is not timelock-owned");

        writeAddress("choice.buybackBurnSink", sink);

        console.log("");
        console.log("What still has to happen. The sink PARKS everything until these land,");
        console.log("so none of it is optional and none of it can brick a harvest either.");
        console.log("");

        _requireLockers(sink);
        uint256 beforeTurnOn = outstanding;
        _requireTranche(sink);
        _requireOperator(sink);
        _requireBuybackPool(sink);
        _requireGuards(sink);
        _reportQuoteRoutes(sink);

        console.log("");
        if (outstanding == 0) {
            console.log("  The sink is configured. It converts, buys back and burns.");
        } else {
            console.log(string.concat("  ", vm.toString(outstanding), " timelock step(s) OUTSTANDING - see above."));
            if (outstanding > beforeTurnOn) {
                console.log("  The turn-on steps are ONE batch: script/15_ConfigureBuybackViaTimelock.s.sol.");
            }
            console.log("  Re-run this script after they land; it is idempotent and will confirm them.");
        }
    }

    /// @dev The sink's CREATE3 payload. The one place it is built: script 13 deploys it through
    /// the timelock, and a batch that encoded its own copy could drift from what this script
    /// would have broadcast.
    ///
    /// 🔴 The hash the factory checks is of the WHOLE payload, constructor arguments included -
    /// hashing the bare `creationCode` fails with `CreationCodeHashMismatch`.
    function _sinkPayload(
        address burnToken,
        address quote,
        address vault,
        address positionManager,
        address treasury,
        address timelock
    ) internal view returns (bytes memory) {
        return abi.encodePacked(
            vm.getCode("BuybackBurnSink.sol:BuybackBurnSink"),
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

        address[] memory installed = IBuybackBurnSink(sink).lockers();
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
        _printTimelockPayloads(sink, abi.encodeCall(IBuybackBurnSink.setLockers, (wanted)));
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
            (,, bool found) = IBuybackBurnSink(sink).quoteRoute(Currency.wrap(assets[i]));
            console.log(found ? "  [ok]   quote route" : "  [TODO] quote route MISSING for", assets[i]);
        }
    }

    /// @dev The live locker, plus EVERY superseded one still holding graduated positions.
    ///
    /// 🔴 There are THREE generations on testnet and this function used to know about two.
    /// The `X` / `XLegacy` pair was written when that was the whole world; the 2026-09-08 core
    /// cutover added `positionLockerPrevious` (1.1.0, launches 19-20) between them, and this read
    /// straight past it. The consequence is not a missing entry in a log - the list it builds IS
    /// the `setLockers` argument, so the timelock payload this script prints would have SILENTLY
    /// DROPPED the 1.1.0 locker, and `convert` on launches 19-20 would answer
    /// `LaunchDoesNotTrade` for ever, with the sink reporting itself correctly configured.
    /// Found 2026-09-10 while wiring sink 1.4.0.
    ///
    /// ⚠️ The list is EVERY locker whose launches should stay convertible, not just the live one,
    /// and ORDER matters twice over: `_requireLockers` compares it element-wise against what is
    /// installed, and `launchPool(id)` returns the FIRST locker holding an id, so the oldest
    /// generations must come after the live one for a fresh launch to win an id collision.
    /// Every optional key is skipped when absent, so a fresh deployment still gets a list of one.
    ///
    /// 🔴 FOUR generations since the 2026-09-11 cutover: the 1.2.0 locker moved to
    /// `positionLocker120` when 1.3.0 became `positionLocker`, and it holds every graduate of the
    /// 2026-09-08 core. The same read-straight-past-it mistake as above was one key away from
    /// repeating, so it is read here explicitly rather than by renaming `Previous` under it.
    function _wantedLockers() internal view returns (address[] memory wanted) {
        address live = readAddress("choice.positionLocker");
        address gen120 = readAddressOrZero("choice.positionLocker120");
        address previous = readAddressOrZero("choice.positionLockerPrevious");
        address legacy = readAddressOrZero("choice.positionLockerLegacy");
        requireCode("positionLocker", live);

        uint256 n = 1;
        if (gen120 != address(0)) n++;
        if (previous != address(0)) n++;
        if (legacy != address(0)) n++;

        wanted = new address[](n);
        uint256 i;
        wanted[i++] = live;
        if (gen120 != address(0)) {
            requireCode("positionLocker120", gen120);
            wanted[i++] = gen120;
        }
        if (previous != address(0)) {
            requireCode("positionLockerPrevious", previous);
            wanted[i++] = previous;
        }
        if (legacy != address(0)) {
            requireCode("positionLockerLegacy", legacy);
            wanted[i++] = legacy;
        }
    }

    /// @dev Until `setGuards` is called `maxImpactBps` is 0, which truncates to a price limit the
    /// pool refuses, so every swap parks. It is the LAST call in script 15's batch: the switch.
    function _requireGuards(address sink) internal {
        IBuybackBurnSink s = IBuybackBurnSink(sink);
        if (
            s.maxImpactBps() == MAX_IMPACT_BPS && s.minBuybackAmount() == MIN_BUYBACK
                && s.minBuybackInterval() == MIN_INTERVAL
        ) {
            console.log("  [ok]   buybackBurnSink.setGuards");
            return;
        }
        outstanding++;
        console.log("  [TODO] the guards are not the batch's, so every buyback and every conversion parks");
    }

    /// @dev The tranche cap: at most this much `QUOTE` per buyback, on either path, and the most
    /// one conversion may be worth. Mandatory since 1.8.0: until it is set, nothing trades.
    function _requireTranche(address sink) internal {
        if (IBuybackBurnSink(sink).maxBuybackAmount() == MAX_BUYBACK) {
            console.log("  [ok]   buybackBurnSink.setMaxBuybackAmount");
            return;
        }
        outstanding++;
        console.log("  [TODO] the tranche cap is not the batch's, so nothing trades");
    }

    /// @dev The key that runs the scheduled TWAP buyback, from `launchpad.buybackOperator` in the
    /// address book. Script 15 refuses to build a batch without one. Without an operator the
    /// permissionless path would always be open, buying whenever somebody calls, spikes included.
    function _requireOperator(address sink) internal {
        address wanted = readAddressOrZero("launchpad.buybackOperator");
        IBuybackBurnSink s = IBuybackBurnSink(sink);
        if (wanted != address(0) && s.operator() == wanted && s.publicFallbackDelay() == FALLBACK_DELAY) {
            console.log("  [ok]   buybackBurnSink.setOperator", wanted);
            return;
        }
        outstanding++;
        if (wanted == address(0)) {
            console.log("  [TODO] no operator in the address book (launchpad.buybackOperator)");
            console.log("           generate a keystore key for the keeper, record it, re-run");
            return;
        }
        console.log("  [TODO] the operator is not installed:", wanted);
    }

    /// @dev The one pool the sink cannot be told about by a caller: the buyback's own. Since 1.8.0
    /// it is named by the burn token's LAUNCH ID, and the sink reads the key and the locked
    /// position it sizes every buyback against off the lockers.
    function _requireBuybackPool(address sink) internal {
        IBuybackBurnSink s = IBuybackBurnSink(sink);
        uint256 burnTokenLaunchId = readUint("launchpad.burnTokenLaunchId");
        if (s.buybackAnchor() != 0 && s.buybackLaunchId() == burnTokenLaunchId) {
            console.log("  [ok]   buybackBurnSink.setBuybackLaunch, anchor", s.buybackAnchor());
            return;
        }
        outstanding++;
        (, address locker) = s.launchPool(burnTokenLaunchId);
        if (locker == address(0)) {
            console.log("  [TODO] no installed locker knows launch", burnTokenLaunchId);
            return;
        }
        console.log("  [TODO] the buyback launch is unset, so quote revenue parks:", burnTokenLaunchId);
    }

    /// @dev Both halves, because matching `execute`'s arguments to the `schedule` they came
    /// from is the whole trick with a `TimelockController`.
    function _printTimelockPayloads(address target, bytes memory payload) internal view virtual {
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
