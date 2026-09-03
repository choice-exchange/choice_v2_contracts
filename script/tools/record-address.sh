#!/usr/bin/env bash
# Record a deployed address in the Choice address book AND in every fork script config that
# needs it, in one step.
#
#   record-address.sh infinity.vault 0x17BD... core:vault periphery:vault
#
# The address book (deployments/injective_<network>.json) is the single source of truth, but
# the Infinity fork scripts read their own script/config/<network>.json and each script reads
# what the previous one deployed. Keeping the two in sync by hand is how a deploy ends up
# wired to a stale address, so they are written together or not at all.
#
# Refuses to record an address with no code on chain: on Injective a broadcast reports failure
# for a tx that landed, so the only trustworthy confirmation is eth_getCode, and it belongs
# here rather than in the operator's memory.
set -euo pipefail

CHOICE_V2="${CHOICE_V2:-/home/dan/workspace/injective/choice_v2}"
NETWORK="${NETWORK:-injective_testnet}"
SCRIPT_CONFIG="${SCRIPT_CONFIG:-injective-testnet}"
RPC_URL="${RPC_URL:-https://k8s.testnet.json-rpc.injective.network}"

[ $# -ge 2 ] || { echo "usage: $0 <book.key.path> <address> [core:key|periphery:key ...]" >&2; exit 64; }
book_key="$1"; addr="$2"; shift 2

[[ "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "not an address: $addr" >&2; exit 65; }

code="$(cast code "$addr" --rpc-url "$RPC_URL")"
[ "${#code}" -gt 2 ] || { echo "REFUSING: no code at $addr on $RPC_URL" >&2; exit 66; }

book="$CHOICE_V2/contracts/deployments/${NETWORK}.json"
jq --arg a "$addr" "setpath([\"${book_key//./\",\"}\"]; \$a)" "$book" > "$book.tmp" && mv "$book.tmp" "$book"
echo "book  ${book_key} = ${addr}  (${#code} hex chars of code)"

for target in "$@"; do
  fork="${target%%:*}"; key="${target#*:}"
  case "$fork" in
    core)       cfg="$CHOICE_V2/forks/infinity-core/script/config/${SCRIPT_CONFIG}.json" ;;
    periphery)  cfg="$CHOICE_V2/forks/infinity-periphery/script/config/${SCRIPT_CONFIG}.json" ;;
    *) echo "unknown fork '$fork'" >&2; exit 64 ;;
  esac
  jq --arg a "$addr" --arg k "$key" '.[$k] = $a' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  echo "  ${fork}.${key} = ${addr}"
done
