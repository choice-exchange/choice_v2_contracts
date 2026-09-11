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
# 🔴 The 1.2.0 router, deployed 2026-09-07, REPLACING 1.0.0 0x4c7d611F09FB896cd3517cA92CcE6B5d2808DfE7.
# The superseded one is left in place, timelock-owned, with nothing pointing at it, and is
# deliberately NOT verified from here - a manifest that verifies dead contracts is how three live
# CREATE3 contracts sat unverified for a day with nothing reporting a failure (see the settler note
# above). ⚠️ 1.1.0 0xdfa954e35851D71c3c6a4D6c35ACF957bE4CE88f is NOT in this list either and never
# should be: it was byte-identical to 1.0.0 and is abandoned unowned. See meta.forkPinsNote.
UR=0x6F82761E0103846E4F4588DB5B7A5505A2907B04
B32Z=0x0000000000000000000000000000000000000000000000000000000000000000
CLQ=0xb7a4f84508c36255Bc29cc4dECaD6cBabd651a60
BNQ=0x0e41128C6Eb88E1DDc97683d78Cf58035eeabD46
DESC=0xd5817F090C8F9939e086861d6EEAB95004072956
POSM=0x823F6dBB3e92f15FdA79A6b0e11e47dB1f3FEd54
# 🔴 FOUR GENERATIONS NOW. The 2026-09-08 cutover deployed a new core, and because the settler
# holds its core AND its locker as immutables, that dragged a new locker and a new settler with
# it; the 2026-09-11 cutover onto the launchpad's ATOMIC core did it again. Every generation
# stays here: verification hashes CONSTRUCTOR ARGUMENTS, so a superseded contract can only ever
# be verified against the arguments it was actually born with.
CORE=0x54a9bC5300b483eD202333Cd1bDa1f886CdB10C0
CORE_0908=0xE7f90bF233e817a157acBc9BEac99926d7c5a679
CORE_PREV=0xb03fb1c05f7853601ae05ba7e3700a59dc14a71d
PADT=0xBf08c09Fe227ada4A86d279e98E695344848d33D
# 🔴 The LIVE settler and locker (1.4.0 / 1.3.0, the atomic core's). This list named the 1.0.0
# pair until 2026-09-06, so for a whole day it verified two dead contracts and left the two the
# pad actually used unverified - which is how three CREATE3 contracts sat unverified without
# anything reporting a failure. That is the drift the header below warns about, caught.
SETTLER=0xa53e2c2D01A91EE92aEd79B3df1BEfd98Ed1Fb27
SETTLER_13=0x4D21e3f398a1Fa3bF3c957Fa775F4C2851634437
SETTLER_12=0xe06aFC826Aa2d7C86b6C1f17ef4C8A8173756182
LOCKER=0x59aF6364F1aC80c452Bb68ED8F83804D31caa67f
LOCKER_12=0xB7999fa35085F106d0E021260F1253a085D8cDea
LOCKER_11=0x0f0Df7bDa12Bea99A5A514b11f7cF6314C038bF5
# The 1.0.0 PUSH locker. Not verified from here - it predates this repo's source, which is
# exactly why it is not in the manifest - but it IS a constructor argument of the A9 cranker.
LOCKER_LEGACY=0x9b28F31B8AB8ED488B4E8bc7cb432ceaFe60E3Fe
# ⛔ The guard hook was constructed with the 1.0.0 SETTLER as its `_initializer` and is not
# redeployed, so its arguments must keep that address. Verification hashes the arguments as
# CONSTRUCTED - `setInitializer` since then does not change them.
SETTLER_10=0xC3ED6d3f97D85B243108446a17ed53d896331ac9
GUARD=0xdbe06EC41E59ad95E9Ade80f8c3eAb34c812512B
# The buyback sink and the TEST burn token it destroys. 🔴 `BBSINK` is 1.2.0, the A5 sink deployed
# 2026-09-06; 1.1.0 is kept below because it is still deployed and still timelock-owned, while
# the two IT superseded, 0xe0248Ebc… and 0x498b0ABd…, are intentionally absent — nothing points
# at either and re-verifying a dead contract on every pass buys nothing.
#
# 🔴 Its constructor `_owner` is the TIMELOCK, unlike sink 1.0.0's, which took the deploy EOA and
# was handed over afterwards. Both are CREATE3 deploys from script 09 and born timelock-owned, so
# there is no handover and no EOA in its arguments. Verification hashes the args as CONSTRUCTED,
# so carrying 1.0.0's $DEPLOYER forward would fail with a bytecode mismatch that reads like a
# compiler-settings problem.
BURN_TOKEN=0xD21C10dCb94cD049f9544cc35D2bE6A76fD8D835
# 🔴 The LIVE sink is 1.3.0 (plan A2 - quote routes and the two-leg conversion). 1.2.0 and 1.1.0
# stay verified and in this list: both are still deployed and still timelock-owned, and a
# superseded contract that reads as unverified is exactly how a reader concludes the wrong one is
# current. ⚠️ Only 1.3.0 is fed - B6 repointed BOTH lockers' `launchpadTreasury` at it.
BBSINK=0x4435DD1a7f61FEfFc00d9283855c9Cc42D29c96D
BBSINK_120=0xd8aDFa9E13d9116914837A381392EE2EEf595d4B
BBSINK_110=0xcC707724b5B91b17ef398E11257E1a61b10bdF20
# 🔴 Sink 1.5.0 is the live one (`choice.buybackBurnSink` since 2026-09-10) and the 2026-09-11
# locker and cranker were CONSTRUCTED against it, so their rows hash this address.
#
# ✅ Both 1.5.0 and 1.4.0 are verified as of 2026-09-12, and 1.5.0 has a row below.
# 🔴 The note that used to sit here — "its constructor changed shape again for the derived quote
# hop" — was WRONG, and believing it is what kept the row unwritten. The shape is IDENTICAL to
# 1.2.0/1.3.0's eight arguments. What changed is two VALUES, and both are why a copied row fails:
#   - the burn token is $BURN_TOKEN_S, not $BURN_TOKEN (a different, later test SPROUT), and
#   - the bps pair is 5000/7000, not 8000/8000 (the B2 numbers, whose floor is an IMMUTABLE).
# Read off the bytes actually deployed rather than from any of that:
# `broadcast/09_DeployBuybackBurnSink.s.sol/1439/run-1789026244612.json`, last 256 bytes of the
# CREATE3 payload's `creationCode` argument — confirmed byte-identical to the row below.
BBSINK_150=0x061b6e7056d7Ec8B271BfC77cFEDDfaf30916748
# The burn token 1.4.0 and 1.5.0 were constructed against. NOT $BURN_TOKEN above, which is the
# earlier test token the 1.1.0-1.3.0 sinks burn — they are both live, and a row that crosses them
# fails with a bytecode mismatch that reads like a compiler-settings problem.
BURN_TOKEN_S=0xEDF52618Cf3C61Be2a721d964C5064c87970331E
# ⛔ Sink 1.4.0 (0xeC9f701C…) deliberately has NO ROW, and this is not an oversight to fix.
# It was built from commit ee3289b, BEFORE 88293f3 added the derived quote hop, so its creation
# code is 19,173 bytes against this tree's 20,405 — the whole 1.4.0 payload is SMALLER than
# today's code alone. This manifest compiles from the WORKING TREE, so a row for it could never
# pass from `main`; it would turn a green gate red for ever and teach a reader to ignore it.
# It IS verified (2026-09-12) — from its own revision, which is the recipe if it is ever lost:
#   git worktree add --detach /tmp/sink140 ee3289b && ln -s "$PWD/lib" /tmp/sink140/lib
#   ./script/tools/verify-blockscout.sh /tmp/sink140 0xeC9f701C3b514274f872a05Cf20fE81e8E474910 \
#       src/fees/BuybackBurnSink.sol:BuybackBurnSink <the same ctor hex as the 1.5.0 row>
# (The arguments are identical to 1.5.0's — only the code differs.)
# 🔴 The cranker moves in LOCKSTEP with the sink: its `SINK` is immutable and it calls functions
# that only exist from a given sink version, so 1.3.0's sink forced cranker 1.1.0. 1.0.0 stays
# listed for the same reason the old sinks do - it is deployed, and it drives the 1.2.0 sink.
# 2.1.0 (2026-09-11) is 2.0.0's bytecode bound to locker 1.3.0 - one cranker per locker.
CRANKER=0x67c9E0feC2E5109A164f254D8FDd86C4d2471Dab
CRANKER_200=0x8454d7022E2cF7B26DB1B296a40a67c147f0d193
CRANKER_11=0x5A1702665EFF2C6A94053518cc26d3c2D1c6f576
CRANKER_100=0x4Ffcd7a35A041A4a776C38417cde2CAb80f9c15d
# 🔴 The A9 instance: the SAME bytecode against the LEGACY (1.0.0, push) locker, so its
# constructor arguments differ in ONE word and it is a separate row rather than a re-verify.
# Two crankers exist because the cranker's LOCKER is immutable and each generation's launches
# are invisible to the other's instance.
CRANKER_LEGACY=0x667fB75FE972097E40b7eB3eB997442E517231f2
# ⚠️ The 1.0.0 PUSH locker 0x9b28F31B… is NOT in the manifest and is deliberately left out even
# though A5 made it load-bearing again (it holds launches 13-17 and is in the sink's locker set).
# It is already verified on Blockscout, it was deployed before this manifest existed, and its
# constructor `launchpadTreasury` was the twice-superseded sink 0xe0248Ebc rather than anything
# the address book still names - so a row for it would have to hard-code an address nothing else
# uses. Check it by hand if it ever reads as unverified.

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
"0xBC9943B5826F8543F42234bb05d3CDA36C6240Fe|contracts|src/fees/ChoiceFeeController.sol:ChoiceFeeController|$(CA address,address,address $CLPM $SAFE $DSINK)"
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
# 🔴 `$PADT`, not the sink. `launchpadTreasury` is owner-settable and was repointed at the
# buyback sink on 2026-09-06 (plan B6); the constructor took the pad treasury, and that is what
# verification hashes.
# 🔴 `$BBSINK`, not `$PADT`, for the 1.2.0 locker: script 05 now reads `choice.buybackBurnSink`
# for this argument so a fresh locker is BORN with plan B6 applied instead of needing a timelock
# `setLaunchpadTreasury` afterwards. The 1.1.0 row below still hashes `$PADT` because that IS
# what its constructor took — the field was repointed later, and a setter does not change the
# creation code verification checks against.
"$LOCKER|contracts|src/launchpad/PositionLocker.sol:PositionLocker|$(CA address,address,address,address $POSM $BBSINK_150 $TL $SETTLER)"
"$LOCKER_12|contracts|src/launchpad/PositionLocker.sol:PositionLocker|$(CA address,address,address,address $POSM $BBSINK $TL $SETTLER_13)"
"$LOCKER_11|contracts|src/launchpad/PositionLocker.sol:PositionLocker|$(CA address,address,address,address $POSM $PADT $TL $SETTLER_12)"
"$GUARD|contracts|src/launchpad/LaunchPoolGuardHook.sol:LaunchPoolGuardHook|$(CA address,address $TL $SETTLER_10)"
"$SETTLER|contracts|src/launchpad/InfinitySettler.sol:InfinitySettler|$(CA address,address,address,address,address,address,address $CORE $CLPM $POSM $P2 $LOCKER $GUARD $TL)"
"$SETTLER_13|contracts|src/launchpad/InfinitySettler.sol:InfinitySettler|$(CA address,address,address,address,address,address,address $CORE_0908 $CLPM $POSM $P2 $LOCKER_12 $GUARD $TL)"
"$SETTLER_12|contracts|src/launchpad/InfinitySettler.sol:InfinitySettler|$(CA address,address,address,address,address,address,address $CORE_PREV $CLPM $POSM $P2 $LOCKER_11 $GUARD $TL)"
"0x3C6724629A341958a1Faf147aA3dC12C5C3A8E98|contracts|src/router/ChoiceRouter.sol:ChoiceRouter|$(CA 'address,address,address[]' $TL $P2 "[$VAULT]")"
# 🔴 The 1.2.0 constructor gained the CL position manager - the contract the sink asks for a
# graduate's real pool key (plan A5). Seven arguments became eight, so 1.1.0's row below cannot
# be reused for it; a stale copy would fail with a bytecode mismatch reading like a compiler
# settings problem.
"$BBSINK|contracts|src/fees/BuybackBurnSink.sol:BuybackBurnSink|$(CA address,address,address,address,address,address,uint16,uint16 $BURN_TOKEN $WETH $VAULT $POSM $SAFE $TL 8000 8000)"
"$BBSINK_120|contracts|src/fees/BuybackBurnSink.sol:BuybackBurnSink|$(CA address,address,address,address,address,address,uint16,uint16 $BURN_TOKEN $WETH $VAULT $POSM $SAFE $TL 8000 8000)"
"$BBSINK_110|contracts|src/fees/BuybackBurnSink.sol:BuybackBurnSink|$(CA address,address,address,address,address,uint16,uint16 $BURN_TOKEN $WETH $VAULT $SAFE $TL 8000 8000)"
# 1.5.0 — the LIVE sink. Same eight-argument shape as 1.2.0/1.3.0 above; the later burn token and
# the 5000/7000 bps are what make it a separate row rather than a re-verify. See the block above
# for why 1.4.0 has none.
"$BBSINK_150|contracts|src/fees/BuybackBurnSink.sol:BuybackBurnSink|$(CA address,address,address,address,address,address,uint16,uint16 $BURN_TOKEN_S $WETH $VAULT $POSM $SAFE $TL 5000 7000)"
# 🔴 2.0.0 takes THREE arguments, not two: `setSink`/`setLocker` moved behind the timelock, so
# the constructor gained an owner. A 1.x row cannot be reused for it and vice versa.
"$CRANKER|contracts|src/launchpad/LaunchFeeCranker.sol:LaunchFeeCranker|$(CA address,address,address $LOCKER $BBSINK_150 $TL)"
"$CRANKER_200|contracts|src/launchpad/LaunchFeeCranker.sol:LaunchFeeCranker|$(CA address,address,address $LOCKER_12 $BBSINK $TL)"
"$CRANKER_11|contracts|src/launchpad/LaunchFeeCranker.sol:LaunchFeeCranker|$(CA address,address $LOCKER_11 $BBSINK)"
"$CRANKER_LEGACY|contracts|src/launchpad/LaunchFeeCranker.sol:LaunchFeeCranker|$(CA address,address $LOCKER_LEGACY $BBSINK)"
"$CRANKER_100|contracts|src/launchpad/LaunchFeeCranker.sol:LaunchFeeCranker|$(CA address,address $LOCKER $BBSINK_120)"
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
