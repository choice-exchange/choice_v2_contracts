#!/usr/bin/env bash
# Verify every Choice v2 contract on Blockscout, retrying the ones its indexer has not caught
# up to yet.
#
# Blockscout refuses verification with "The address is not a smart contract" until ITS OWN
# indexer has flagged the address, which on Injective testnet lags the chain by minutes to
# hours and does not arrive in deploy order. eth_getCode says 40 KB while Blockscout still says
# is_contract=false. So this loops rather than failing: each pass verifies whatever has become
# available and reports what is still waiting.
set -uo pipefail

CHOICE_V2="${CHOICE_V2:-/home/dan/workspace/injective/choice_v2}"
API="${BLOCKSCOUT_API:-https://testnet.blockscout-api.injective.network}"
V="$CHOICE_V2/contracts/script/tools/verify-blockscout.sh"
PASSES="${PASSES:-40}"
INTERVAL="${INTERVAL:-120}"

CA(){ cast abi-encode "f($1)" "${@:2}"; }
VAULT=0x17BDb95424cA07c31C23ecA9925CBA10818CBF6e
CLPM=0x0d93E2E86e308F54eFca3f225487382cECF57F37
BPM=0x88Af37259DB7775B4625449AeEa11Fc682452143
SAFE=0x0ee0Db41E787FdFcD0a35680074935C6bdC00237
TL=0xfE9811111Cffd823aA2c1c8F31A77009BFaeDE42
DSINK=0xEAf8ED7b6c9e425b45199839be5e9D3F2a791215
P2=0x000000000022D473030F116dDEE9F6B43aC78BA3
WETH=0x0000000088827d2d103ee2d9A6b781773AE03FfB
DEAD=0x000000000000000000000000000000000000dEaD
UNSUP=0xCB7340356Df545a6DCc10998078F3E0089640E2d
UR=0x4c7d611F09FB896cd3517cA92CcE6B5d2808DfE7
B32Z=0x0000000000000000000000000000000000000000000000000000000000000000
CLQ=0xb7a4f84508c36255Bc29cc4dECaD6cBabd651a60
BNQ=0x0e41128C6Eb88E1DDc97683d78Cf58035eeabD46
DESC=0xd5817F090C8F9939e086861d6EEAB95004072956
POSM=0x823F6dBB3e92f15FdA79A6b0e11e47dB1f3FEd54
CORE=0xb03fb1c05f7853601ae05ba7e3700a59dc14a71d
PADT=0xBf08c09Fe227ada4A86d279e98E695344848d33D
SETTLER=0xC3ED6d3f97D85B243108446a17ed53d896331ac9
LOCKER=0x9b28F31B8AB8ED488B4E8bc7cb432ceaFe60E3Fe
GUARD=0xdbe06EC41E59ad95E9Ade80f8c3eAb34c812512B
# The buyback sink and the TEST SPROUT it burns. 🔴 `BBSINK` is 1.1.0, the A4 sink deployed
# 2026-09-06; the two it supersedes, 0xe0248Ebc… and 0x498b0ABd…, are intentionally absent —
# nothing points at either and re-verifying a dead contract on every pass buys nothing.
#
# 🔴 Its constructor `_owner` is the TIMELOCK, unlike 1.0.0's, which took the deploy EOA and was
# handed over afterwards. 1.1.0 is a CREATE3 deploy from script 09 and is born timelock-owned, so
# there is no handover and no EOA in its arguments. Verification hashes the args as CONSTRUCTED,
# so carrying 1.0.0's $DEPLOYER forward would fail with a bytecode mismatch that reads like a
# compiler-settings problem.
SPROUT=0xD21C10dCb94cD049f9544cc35D2bE6A76fD8D835
BBSINK=0xcC707724b5B91b17ef398E11257E1a61b10bdF20

# address | fork-dir | src path:Name | constructor args (hex, may be empty)
#
# ⚠️ This list is hand-maintained and has silently fallen behind twice — it never gained the
# BuybackBurnSink after #11 deployed one, and the UniversalRouter sat outside it for a whole
# milestone because nothing had encoded its `RouterParameters` struct. Both are in now, but the
# lesson stands: "verify-all passed" means "every contract IN THIS LIST is verified", never
# "every contract we deployed is". Add the row in the same change that deploys the contract.
MANIFEST=(
"0x17BDb95424cA07c31C23ecA9925CBA10818CBF6e|infinity-core|src/Vault.sol:Vault|"
"$CLPM|infinity-core|src/pool-cl/CLPoolManager.sol:CLPoolManager|$(CA address $VAULT)"
"$BPM|infinity-core|src/pool-bin/BinPoolManager.sol:BinPoolManager|$(CA address $VAULT)"
"0xC46e1388834077F64600f039DbD942Db0ad550D7|infinity-core|src/pool-cl/CLPoolManagerOwner.sol:CLPoolManagerOwner|$(CA address $CLPM)"
"0xB1d448ec21A2845980BfFCA92370ba25Da573995|infinity-core|src/pool-bin/BinPoolManagerOwner.sol:BinPoolManagerOwner|$(CA address $BPM)"
"0x36ab137ac1647c16646CA851c2715FBb60f4FD3C|contracts|src/fees/ChoiceFeeController.sol:ChoiceFeeController|$(CA address,address,address $CLPM $SAFE $DSINK)"
"0x1aceba7d060Af651553fE850C17938e2F0580066|contracts|src/fees/ChoiceFeeController.sol:ChoiceFeeController|$(CA address,address,address $BPM $SAFE $DSINK)"
"$DSINK|contracts|src/fees/DirectTransferBurnSink.sol:DirectTransferBurnSink|"
"0xefe613636921D9d683CDe6d91FD0485D9DD2987f|contracts|src/fees/ExchangeSubaccountBurnSink.sol:ExchangeSubaccountBurnSink|$(CA address $TL)"
"$TL|contracts|lib/infinity-core/lib/openzeppelin-contracts/contracts/governance/TimelockController.sol:TimelockController|$(CA 'uint256,address[],address[],address' 60 "[$SAFE]" "[0x0000000000000000000000000000000000000000]" 0x0000000000000000000000000000000000000000)"
"$DESC|infinity-periphery|src/pool-cl/CLPositionDescriptorOffChain.sol:CLPositionDescriptorOffChain|$(CA string 'https://testnet.choice.exchange/v2/position/')"
"0x823F6dBB3e92f15FdA79A6b0e11e47dB1f3FEd54|infinity-periphery|src/pool-cl/CLPositionManager.sol:CLPositionManager|$(CA address,address,address,uint256,address,address $VAULT $CLPM $P2 200000 $DESC $WETH)"
"0x6D255544204E318b99eE3E0CE39Fa111799548CC|infinity-periphery|src/pool-bin/BinPositionManager.sol:BinPositionManager|$(CA address,address,address,address $VAULT $BPM $P2 $WETH)"
"$CLQ|infinity-periphery|src/pool-cl/lens/CLQuoter.sol:CLQuoter|$(CA address $CLPM)"
"$BNQ|infinity-periphery|src/pool-bin/lens/BinQuoter.sol:BinQuoter|$(CA address $BPM)"
"0x95B0B855108CA5A8D5c43D9bc3A5994A479043e0|infinity-periphery|src/MixedQuoter.sol:MixedQuoter|$(CA address,address,address,address,address,address $DEAD $DEAD $DEAD $WETH $CLQ $BNQ)"
"0x9D29c5BA79Ff9b173EADa6b8C0Fae10307cC9400|infinity-periphery|src/pool-cl/lens/TickLens.sol:TickLens|$(CA address $CLPM)"
"$UNSUP|infinity-universal-router|src/deploy/UnsupportedProtocol.sol:UnsupportedProtocol|"
"$LOCKER|contracts|src/launchpad/PositionLocker.sol:PositionLocker|$(CA address,address,address,address $POSM $PADT $TL $SETTLER)"
"$GUARD|contracts|src/launchpad/LaunchPoolGuardHook.sol:LaunchPoolGuardHook|$(CA address,address $TL $SETTLER)"
"$SETTLER|contracts|src/launchpad/InfinitySettler.sol:InfinitySettler|$(CA address,address,address,address,address,address,address $CORE $CLPM $POSM $P2 $LOCKER $GUARD $TL)"
"0x3C6724629A341958a1Faf147aA3dC12C5C3A8E98|contracts|src/router/ChoiceRouter.sol:ChoiceRouter|$(CA 'address,address,address[]' $TL $P2 "[$VAULT]")"
"$BBSINK|contracts|src/fees/BuybackBurnSink.sol:BuybackBurnSink|$(CA address,address,address,address,address,uint16,uint16 $SPROUT $WETH $VAULT $SAFE $TL 8000 8000)"
# 🔴 ONE argument: a static `RouterParameters` struct, so it encodes as 12 flat words with NO
# offset head — which is why the whole thing is a single parenthesised tuple here rather than a
# list of scalars. Confirmed byte-identical (all 384) against the bytes actually deployed:
# broadcast/forks/infinity-universal-router/DeployInjectiveTestnet.s.sol/1439/run-latest.json
# carries the CREATE3 `deploy(...)` call, and these are the tail of its `creationCode` argument.
# ⛔ The five UNSUPPORTED slots are NOT address(0). `DeployUniversalRouter.run()` maps every
# address(0) through `mapUnsupported` to the UnsupportedProtocol it deploys in the same run, so
# the struct that reached the constructor holds $UNSUP five times. Encoding the zeros the
# deployParameters file literally says would fail as a bytecode mismatch.
"$UR|infinity-universal-router|src/UniversalRouter.sol:UniversalRouter|$(CA '(address,address,address,address,address,bytes32,bytes32,address,address,address,address,address)' "($P2,$WETH,$UNSUP,$UNSUP,$UNSUP,$B32Z,$B32Z,$UNSUP,$UNSUP,$VAULT,$CLPM,$BPM)")"
)

for pass in $(seq 1 "$PASSES"); do
  remaining=0
  for row in "${MANIFEST[@]}"; do
    IFS='|' read -r addr dir target ctor <<< "$row"
    meta="$(curl -s -m 15 "$API/api/v2/addresses/$addr")"
    [ "$(echo "$meta" | jq -r .is_verified)" = "true" ] && continue
    if [ "$(echo "$meta" | jq -r .is_contract)" != "true" ]; then
      remaining=$((remaining+1)); continue
    fi
    "$V" "$dir" "$addr" "$target" "$ctor" || remaining=$((remaining+1))
  done
  echo "--- pass $pass: $remaining still waiting on the Blockscout indexer ---"
  [ "$remaining" -eq 0 ] && { echo "ALL VERIFIED"; exit 0; }
  sleep "$INTERVAL"
done
echo "gave up after $PASSES passes; $remaining unverified"
