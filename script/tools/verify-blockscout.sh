#!/usr/bin/env bash
# Verify one contract on Injective's Blockscout.
#
#   verify-blockscout.sh <fork-dir|contracts> <address> <src/Path.sol:Name> [ctor-args-hex]
#
# Two things make `forge verify-contract` unusable here beyond the simplest case, both worked
# around below:
#
# 1. The API is on a DIFFERENT HOST from the explorer UI. testnet.blockscout.injective.network
#    serves the frontend and answers every /api call with an HTML 404; the API is
#    testnet.blockscout-api.injective.network.
# 2. `forge verify-contract` with --constructor-args first tries to find the deployment and
#    dies with "Could not detect deployment: The address is not a smart contract". Injective
#    serves no receipts and no tx-by-hash, so nothing can resolve a creation transaction.
#    Blockscout's own v2 endpoint refuses the same contracts ("Address is not a smart-contract")
#    because its indexer has not flagged them - CREATE3 deploys arrive through a proxy child.
#    The etherscan-compat /api endpoint does no such check and verifies fine.
#
# So: build the standard-json with forge, POST it to the compat endpoint ourselves.
set -euo pipefail

CHOICE_V2="${CHOICE_V2:-/home/dan/workspace/injective/choice_v2}"
API="${BLOCKSCOUT_API:-https://testnet.blockscout-api.injective.network}"
SOLC="${SOLC_VERSION:-v0.8.26+commit.8a97fa7a}"

[ $# -ge 3 ] || { echo "usage: $0 <fork-dir|contracts> <address> <src/Path.sol:Name> [ctor-args-hex]" >&2; exit 64; }
dir="$1"; addr="$2"; target="$3"; ctor="${4:-}"
ctor="${ctor#0x}"

case "$dir" in
  # An absolute path, for a contract whose build lives in neither `contracts` nor a fork: the
  # Create3Factory is compiled from contracts/lib/infinity-core/lib/pancake-create3-factory,
  # a nested submodule with its own foundry profile, and forge must run from THAT root or it
  # cannot produce the standard-json for it.
  /*)        root="$dir" ;;
  contracts) root="$CHOICE_V2/contracts" ;;
  *)         root="$CHOICE_V2/forks/$dir" ;;
esac
[ -d "$root" ] || { echo "no such build root: $root" >&2; exit 66; }

name="${target##*:}"

# Idempotent, and not merely as a courtesy. The compat endpoint answers a CREATE3 contract that
# is ALREADY verified with "Fail - Unable to verify" - it wants a creation-bytecode match and
# there is no creation transaction to match against - so without this check a fully verified
# deployment reports every one of those contracts as a failure, every pass, for ever.
if [ "$(curl -s -m 20 "$API/api/v2/smart-contracts/$addr" | jq -r '.is_verified // false')" = "true" ]; then
  printf "%-28s %s  Already verified\n" "$name" "$addr"
  exit 0
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# infinity-periphery declares an extra compilation profile (`clPosm`, 9000 runs, applied only
# to CLPositionManager.sol) alongside `default`. forge then refuses --show-standard-json-input
# with "Ambiguous compilation profiles found in cache" for contracts in that project, and the
# error goes to stderr while the exit status stays 0 - so an unguarded redirect silently writes
# an EMPTY input file and the verification looks like a Blockscout problem. Try plain first,
# fall back to naming the profile.
err="$( { cd "$root" && forge verify-contract "$addr" "$target" --show-standard-json-input ; } 2>"$tmp/err" >"$tmp/input.json"; cat "$tmp/err" )"
if [ ! -s "$tmp/input.json" ]; then
  ( cd "$root" && forge verify-contract "$addr" "$target" --show-standard-json-input \
      --compilation-profile "${COMPILATION_PROFILE:-default}" ) > "$tmp/input.json" 2>"$tmp/err"
fi
if [ ! -s "$tmp/input.json" ]; then
  printf "%-28s %s  STANDARD-JSON FAILED: %s\n" "${target##*:}" "$addr" "$(head -c 200 "$tmp/err")"
  exit 70
fi

resp="$(curl -s -m 120 -X POST "$API/api" \
  --data-urlencode "module=contract" \
  --data-urlencode "action=verifysourcecode" \
  --data-urlencode "codeformat=solidity-standard-json-input" \
  --data-urlencode "contractaddress=$addr" \
  --data-urlencode "contractname=$target" \
  --data-urlencode "compilerversion=$SOLC" \
  --data-urlencode "constructorArguements=$ctor" \
  --data-urlencode "sourceCode@$tmp/input.json")"

# The v2 route: it asks the verifier microservice for a RUNTIME match, so it needs neither a
# creation transaction nor constructor arguments. That is what makes it work on a CREATE3
# deploy, where the contract is born inside a proxy child and the compat endpoint can find
# nothing to match. Measured 2026-09-06: it verified a sink the compat endpoint had refused 16
# times over 32 minutes, then the settler, locker and fee controller A0 deployed - all CREATE3,
# all unverified for a day - in about a minute.
#
# ⚠️ It reports `constructor_args: null` on what it verifies, because a runtime match cannot
# recover them. The bytecode match is the same; only the argument display is missing.
verify_via_v2() {
  local v2 ok
  v2="$(curl -s -m 180 -X POST "$API/api/v2/smart-contracts/$addr/verification/via/standard-input" \
    -F "compiler_version=$SOLC" \
    -F "contract_name=$target" \
    -F "autodetect_constructor_args=true" \
    -F "license_type=${LICENSE_TYPE:-gnu_gpl_v2}" \
    -F "files[0]=@$tmp/input.json;filename=input.json;type=application/json")"
  case "$v2" in
    *"verification started"*|*"already verified"*) ;;
    *) printf "%-28s %s  V2 SUBMIT FAILED: %s\n" "$name" "$addr" "$(echo "$v2" | head -c 160)"; return 1 ;;
  esac
  for _ in $(seq 1 20); do
    ok="$(curl -s -m 15 "$API/api/v2/smart-contracts/$addr" | jq -r '.is_verified // false')"
    [ "$ok" = "true" ] && { printf "%-28s %s  Pass - Verified (v2)\n" "$name" "$addr"; return 0; }
    sleep 6
  done
  printf "%-28s %s  V2 SUBMITTED BUT NOT VERIFIED\n" "$name" "$addr"
  return 1
}

guid="$(echo "$resp" | jq -r '.result // empty')"
if [ -z "$guid" ] || [ "$(echo "$resp" | jq -r .status)" != "1" ]; then
  verify_via_v2 && exit 0
  printf "%-28s %s  SUBMIT FAILED: %s\n" "$name" "$addr" "$(echo "$resp" | head -c 160)"
  exit 1
fi

for _ in $(seq 1 20); do
  st="$(curl -s -m 15 "$API/api?module=contract&action=checkverifystatus&guid=$guid" | jq -r .result)"
  case "$st" in *Pending*) sleep 6 ;; *) break ;; esac
done
case "$st" in
  *Pass*) printf "%-28s %s  %s\n" "$name" "$addr" "$st" ;;
  # A CREATE3 contract lands here rather than at the submit check: the compat endpoint takes the
  # submission, hands back a guid, and only then says it cannot match.
  *) verify_via_v2 || printf "%-28s %s  %s\n" "$name" "$addr" "$st" ;;
esac
