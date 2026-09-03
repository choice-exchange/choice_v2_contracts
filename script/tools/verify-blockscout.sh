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
  contracts) root="$CHOICE_V2/contracts" ;;
  *)         root="$CHOICE_V2/forks/$dir" ;;
esac

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

guid="$(echo "$resp" | jq -r '.result // empty')"
name="${target##*:}"
if [ -z "$guid" ] || [ "$(echo "$resp" | jq -r .status)" != "1" ]; then
  printf "%-28s %s  SUBMIT FAILED: %s\n" "$name" "$addr" "$(echo "$resp" | head -c 160)"
  exit 1
fi

for _ in $(seq 1 20); do
  st="$(curl -s -m 15 "$API/api?module=contract&action=checkverifystatus&guid=$guid" | jq -r .result)"
  case "$st" in *Pending*) sleep 6 ;; *) break ;; esac
done
printf "%-28s %s  %s\n" "$name" "$addr" "$st"
