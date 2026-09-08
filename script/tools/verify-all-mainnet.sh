#!/usr/bin/env bash
# Verify every Choice v2 MAINNET contract on Blockscout (chain 1776).
#
# The sibling verify-all.sh is testnet-only: its addresses are hardcoded 1439 values and its API
# host defaults to the testnet one. Rather than parameterise a file whose whole value is being a
# hand-maintained, reviewed list of exactly what is live, mainnet gets its own list. Both scripts
# share verify-blockscout.sh, which carries the actual Blockscout workarounds.
#
# 🔴 THE MANIFEST IS THE GUARANTEE, NOT THE SCRIPT. A passing run means "everything in this list",
# never "everything deployed". Add the row in the same change that deploys the contract.
#
# 🔑 Addresses are READ FROM THE ADDRESS BOOK, not retyped, so this file cannot drift from the
# one source of truth. Constructor arguments still have to be written out, because verification
# hashes the arguments a contract was actually born with and nothing on chain can be asked for
# them - Injective serves no creation transaction to decode.
set -uo pipefail

CHOICE_V2="${CHOICE_V2:-/home/dan/workspace/injective/choice_v2}"
BOOK="$CHOICE_V2/contracts/deployments/injective_mainnet.json"
export BLOCKSCOUT_API="${BLOCKSCOUT_API:-https://blockscout-api.injective.network}"
V="$CHOICE_V2/contracts/script/tools/verify-blockscout.sh"
PASSES="${PASSES:-3}"
INTERVAL="${INTERVAL:-60}"

b() { jq -r "$1" "$BOOK"; }
CA() { cast abi-encode "f($1)" "${@:2}"; }

VAULT=$(b .infinity.vault)
CLPM=$(b .infinity.clPoolManager)
BPM=$(b .infinity.binPoolManager)
CLPMO=$(b .infinity.clPoolManagerOwner)
BPMO=$(b .infinity.binPoolManagerOwner)
DESC=$(b .infinity.clPositionDescriptor)
CLPOSM=$(b .infinity.clPositionManager)
BPOSM=$(b .infinity.binPositionManager)
CLQ=$(b .infinity.clQuoter)
BNQ=$(b .infinity.binQuoter)
MXQ=$(b .infinity.mixedQuoter)
LENS=$(b .infinity.clTickLens)
UR=$(b .infinity.universalRouter)
UNSUP=$(b .infinity.unsupportedProtocol)
CLFC=$(b .choice.clFeeController)
BNFC=$(b .choice.binFeeController)
DSINK=$(b .choice.directTransferBurnSink)
ESINK=$(b .choice.exchangeSubaccountBurnSink)
CROUTER=$(b .choice.choiceRouter)
TL=$(b .governance.timelock)
TREASURY=$(b .choice.treasury)
SAFE=$(b .governance.safe)
FACTORY=$(b .governance.create3Factory)
P2=$(b .external.permit2)
WETH=$(b .external.wINJ)
DEAD=0x000000000000000000000000000000000000dEaD
B32Z=0x0000000000000000000000000000000000000000000000000000000000000000
ZERO=0x0000000000000000000000000000000000000000
URI="$(b .infinity.clPositionDescriptorTokenUri 2>/dev/null)"
[ "$URI" = "null" ] && URI="https://choice.exchange/position/"

# The 0.05%-tier fee policy both controllers were CONSTRUCTED with. Read from the book so that a
# later policy change cannot silently invalidate the verification arguments recorded here.
SPLIT=$(b .choice.protocolFeeSplitRatio)
DYN=$(b .choice.defaultProtocolFeeForDynamicFeePool)
DELAY=$(b .governance.timelockMinDelay)

run_pass() {
  # infinity-core
  "$V" infinity-core "$VAULT"  src/Vault.sol:Vault
  "$V" infinity-core "$CLPM"   src/pool-cl/CLPoolManager.sol:CLPoolManager            "$(CA address "$VAULT")"
  "$V" infinity-core "$BPM"    src/pool-bin/BinPoolManager.sol:BinPoolManager         "$(CA address "$VAULT")"
  "$V" infinity-core "$CLPMO"  src/pool-cl/CLPoolManagerOwner.sol:CLPoolManagerOwner  "$(CA address "$CLPM")"
  "$V" infinity-core "$BPMO"   src/pool-bin/BinPoolManagerOwner.sol:BinPoolManagerOwner "$(CA address "$BPM")"

  # infinity-periphery. 🔴 CLPositionManager lives in the `clPosm` compilation profile; without
  # naming it forge refuses --show-standard-json-input as "ambiguous" on stderr while exiting 0.
  "$V" infinity-periphery "$DESC"   src/pool-cl/CLPositionDescriptorOffChain.sol:CLPositionDescriptorOffChain "$(CA string "$URI")"
  COMPILATION_PROFILE=clPosm \
  "$V" infinity-periphery "$CLPOSM" src/pool-cl/CLPositionManager.sol:CLPositionManager \
       "$(CA 'address,address,address,uint256,address,address' "$VAULT" "$CLPM" "$P2" 200000 "$DESC" "$WETH")"
  "$V" infinity-periphery "$BPOSM"  src/pool-bin/BinPositionManager.sol:BinPositionManager \
       "$(CA 'address,address,address,address' "$VAULT" "$BPM" "$P2" "$WETH")"
  "$V" infinity-periphery "$CLQ"    src/pool-cl/lens/CLQuoter.sol:CLQuoter   "$(CA address "$CLPM")"
  "$V" infinity-periphery "$BNQ"    src/pool-bin/lens/BinQuoter.sol:BinQuoter "$(CA address "$BPM")"
  "$V" infinity-periphery "$LENS"   src/pool-cl/lens/TickLens.sol:TickLens    "$(CA address "$CLPM")"
  "$V" infinity-periphery "$MXQ"    src/MixedQuoter.sol:MixedQuoter \
       "$(CA 'address,address,address,address,address,address' "$DEAD" "$DEAD" "$DEAD" "$WETH" "$CLQ" "$BNQ")"

  # infinity-universal-router. The router takes ONE struct, so the encoding is a tuple - the
  # field order is RouterParameters in src/base/RouterImmutables.sol and nothing else.
  # ⚠️ v2Factory / v3Factory / v3Deployer / stableFactory / stableInfo are all the
  # UnsupportedProtocol stub: Injective has no PancakeSwap v2, v3 or StableSwap.
  "$V" infinity-universal-router "$UNSUP" src/deploy/UnsupportedProtocol.sol:UnsupportedProtocol
  "$V" infinity-universal-router "$UR"    src/UniversalRouter.sol:UniversalRouter \
       "$(CA '(address,address,address,address,address,bytes32,bytes32,address,address,address,address,address)' \
            "($P2,$WETH,$UNSUP,$UNSUP,$UNSUP,$B32Z,$B32Z,$UNSUP,$UNSUP,$VAULT,$CLPM,$BPM)")"

  # contracts
  "$V" contracts "$DSINK"   src/fees/DirectTransferBurnSink.sol:DirectTransferBurnSink
  "$V" contracts "$ESINK"   src/fees/ExchangeSubaccountBurnSink.sol:ExchangeSubaccountBurnSink "$(CA address "$TL")"
  "$V" contracts "$CLFC"    src/fees/ChoiceFeeController.sol:ChoiceFeeController \
       "$(CA 'address,address,address,uint256,uint24' "$CLPM" "$TREASURY" "$DSINK" "$SPLIT" "$DYN")"
  "$V" contracts "$BNFC"    src/fees/ChoiceFeeController.sol:ChoiceFeeController \
       "$(CA 'address,address,address,uint256,uint24' "$BPM" "$TREASURY" "$DSINK" "$SPLIT" "$DYN")"
  "$V" contracts "$CROUTER" src/router/ChoiceRouter.sol:ChoiceRouter \
       "$(CA 'address,address,address[]' "$TL" "$P2" "[$VAULT]")"

  # OpenZeppelin's TimelockController, deployed by script 01 from this repo's lib.
  # proposers = [safe]; executors = [address(0)] (open role); admin = address(0).
  "$V" contracts "$TL" \
       lib/infinity-core/lib/openzeppelin-contracts/contracts/governance/TimelockController.sol:TimelockController \
       "$(CA 'uint256,address[],address[],address' "$DELAY" "[$SAFE]" "[$ZERO]" "$ZERO")"

  # The Create3Factory, and it needs BOTH overrides - it is the one contract here built by
  # neither `contracts` nor a fork.
  #
  # 🔴 SOLC_VERSION. Everything else in this manifest is 0.8.26, pinned by its project. This
  # submodule pins no compiler, so forge took the newest it had - 0.8.33 - and a verification
  # sent at the default answers "Fail - Unable to verify", which is indistinguishable from a
  # genuine bytecode mismatch. Read the version out of the artifact's own metadata rather than
  # trusting this constant if it ever fails again:
  #   jq -r .metadata.compiler.version foundry-out/Create3Factory.sol/Create3Factory.json
  #
  # ⚠️ It is NOT a CREATE3 deploy - it is plain CREATE from a nonce-0 EOA - so unlike the
  # contracts above it has a real creation transaction and the compat endpoint can match it.
  SOLC_VERSION="${CREATE3_SOLC:-v0.8.33+commit.64118f21}" \
  "$V" "$CHOICE_V2/contracts/lib/infinity-core/lib/pancake-create3-factory" "$FACTORY" \
       src/Create3Factory.sol:Create3Factory
}

for p in $(seq 1 "$PASSES"); do
  echo "=== pass $p/$PASSES  ($BLOCKSCOUT_API) ==="
  run_pass
  [ "$p" -lt "$PASSES" ] && sleep "$INTERVAL"
done
