#!/usr/bin/env bash
# Assemble, sign and submit one Choice v2 Safe transaction — in three separate steps, so the
# signers do not have to be in the same place at the same time, and so a HARDWARE WALLET can sign.
#
#   safe-tx.sh propose <to> <calldata> [value]        -> safe/<nonce>.json
#   safe-tx.sh sign    <file> --ledger [--hd-path P]  -> safe/<nonce>.<signer>.sig
#   safe-tx.sh sign    <file> --account <keystore>    -> safe/<nonce>.<signer>.sig
#   safe-tx.sh exec    <file> [sig-file ...]          -> execTransaction from any funded key
#   safe-tx.sh show    <file>
#
# WHY THIS EXISTS, and why safe-exec.sh could not just be extended (audit G-7).
# safe-exec.sh signs the Safe's `getTransactionHash` as a RAW 32-BYTE DIGEST (`cast wallet sign
# --no-hash`). A Ledger will not do that: blind-signing an opaque digest is disabled by default on
# the Ethereum app, and it is disabled for exactly the reason that matters here — the device can
# show the user nothing about what they are approving. The device signs EIP-712 TYPED DATA, which
# it can display field by field.
#
# 🔑 THE FACT THAT MAKES THIS SAFE, and it was MEASURED rather than assumed: signing the SafeTx
# typed data produces a signature BYTE-IDENTICAL to signing `getTransactionHash` with --no-hash.
# Verified on 1439 against the live Safe with the same keystore — the two hex strings matched
# exactly. So this tool and safe-exec.sh produce interchangeable signatures, and the typed-data
# route is strictly more capable rather than a different scheme. If that ever stops being true,
# `sign` catches it: it recovers the signer from the Safe's OWN digest and refuses a mismatch.
#
# ⚠️ There is no hosted Safe UI or transaction service for Injective (plan D13), so this file is
# the whole coordination mechanism. The proposal JSON is the artifact a reviewer reads.
#
# ---------------------------------------------------------------------------------------------
# ✅ THE A4 REHEARSAL — DONE 2026-09-08. A Ledger Nano S+ signed a SafeTx and the Safe executed it.
#
# The rehearsal Safe carries the THREE REAL MAINNET OWNERS and lives on 1439 at
#
#     0x053e4204c3031422FBb1B5687f486bCbB565a5D7   (saltNonce 1, threshold 2, Safe 1.4.1)
#
# It is deliberately NOT in the address book: `governance.safe` there is the Safe that actually
# owns testnet's timelock, and the rehearsal must not be able to touch it. SAFE_ADDRESS points
# this tool at it instead. What was executed, nonce 0 -> 1, on two signatures:
# `choicedev` 0x20D150a0... and the LEDGER 0xA379382E... . To repeat it:
#
#   export NETWORK=injective_testnet
#   export SAFE_ADDRESS=0x053e4204c3031422FBb1B5687f486bCbB565a5D7
#   export SAFE_TX_DIR=./safe-rehearsal
#
#   ./script/tools/safe-tx.sh propose $SAFE_ADDRESS $(cast calldata 'getThreshold()')
#   ./script/tools/safe-tx.sh sign  ./safe-rehearsal/0.json --ledger
#   ./script/tools/safe-tx.sh sign  ./safe-rehearsal/0.json --account <choicedev keystore>
#   ./script/tools/safe-tx.sh exec  ./safe-rehearsal/0.json
#
#   cast call $SAFE_ADDRESS 'nonce()(uint256)' --rpc-url $RPC_URL     # advanced by one = landed
#
# 🔴 BLIND SIGNING MUST BE ENABLED ON THE DEVICE, and this is not optional advice - it was hit.
# Ethereum app -> Settings -> Blind signing -> Enabled (older builds call it "Debug data"). The
# symptom is exact and worth recognising rather than re-diagnosing:
#
#     Error: Ledger device: APDU Response error `Code 6a80 ([APDU_CODE_INVALID_DATA] ...)`
#
# The same device signed the plain A5 ceremony MESSAGE fine with the setting off - EIP-191
# personal_sign needs nothing - so "the Ledger works" is not evidence that a SafeTx will sign.
# ⚠️ Injective's Ledger support uses the stock Ethereum app, and the address comes out at the
# DEFAULT path m/44'/60'/0'/0/0; pass --hd-path only if yours differs.
#
# ⚠️ The device LOCKS between calls and each lock breaks the connection, so a propose/sign/exec
# run is not one uninterrupted session - expect to unlock again before the sign step. Ledger Live
# competes for the USB device; if `cast wallet address --ledger` cannot connect, close it.
# ---------------------------------------------------------------------------------------------
set -euo pipefail

CHOICE_V2="${CHOICE_V2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
NETWORK="${NETWORK:-injective_testnet}"
BOOK="$CHOICE_V2/deployments/${NETWORK}.json"
[ -r "$BOOK" ] || BOOK="$CHOICE_V2/contracts/deployments/${NETWORK}.json"
OUT_DIR="${SAFE_TX_DIR:-$(dirname "$BOOK")/../safe}"
ZERO=0x0000000000000000000000000000000000000000

die() { echo "error: $*" >&2; exit 1; }
note() { echo "$*" >&2; }

[ -r "$BOOK" ] || die "no address book at $BOOK (set NETWORK)"
RPC_URL="${RPC_URL:-$(jq -r .rpc "$BOOK")}"

book() { jq -r "$1" "$BOOK"; }
lower() { tr 'A-Z' 'a-z'; }

# ---------------------------------------------------------------------------------------------
# propose
# ---------------------------------------------------------------------------------------------
cmd_propose() {
  [ $# -ge 2 ] || die "usage: $0 propose <to> <calldata> [value]"
  local to="$1" data="$2" value="${3:-0}"
  local safe threshold nonce hash chainid
  # SAFE_ADDRESS overrides the book. It exists for the A4 REHEARSAL: the rehearsal Safe carries
  # the three real mainnet owners on 1439, and it must not be written into the testnet book,
  # because the book's `governance.safe` is the Safe that actually owns testnet's timelock.
  safe="${SAFE_ADDRESS:-$(book .governance.safe)}"
  [ "$safe" != "null" ] || die "no Safe in $BOOK (or set SAFE_ADDRESS)"
  # Owners and threshold come off the CHAIN, never the book, so an override needs no second flag
  # and a book that has drifted cannot produce a proposal nobody can sign.
  threshold="$(cast call "$safe" 'getThreshold()(uint256)' --rpc-url "$RPC_URL")"
  nonce="$(cast call "$safe" 'nonce()(uint256)' --rpc-url "$RPC_URL")"
  chainid="$(cast chain-id --rpc-url "$RPC_URL")"

  # The Safe's own digest. Everything else in this file is checked against it.
  hash="$(cast call "$safe" \
    'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)' \
    "$to" "$value" "$data" 0 0 0 0 "$ZERO" "$ZERO" "$nonce" --rpc-url "$RPC_URL")"

  # Best-effort human summary. A reviewer who cannot read calldata is the reason this exists, so
  # a failure to decode must not fail the proposal — it just leaves the field null.
  local selector decoded label
  selector="${data:0:10}"
  decoded="$(cast 4byte-decode "$data" 2>/dev/null | head -1 || true)"
  label="$(jq -r --arg a "$(echo "$to" | lower)" '
      [paths(scalars) as $p | {k: ($p|join(".")), v: getpath($p)}]
      | map(select((.v|type)=="string" and (.v|ascii_downcase)==$a)) | .[0].k // "unknown"' "$BOOK")"

  mkdir -p "$OUT_DIR"
  local f="$OUT_DIR/${nonce}.json"
  [ -e "$f" ] && die "$f already exists — a proposal for nonce $nonce is already open"

  jq -n --arg net "$NETWORK" --argjson chainId "$chainid" --arg safe "$safe" \
        --argjson nonce "$nonce" --argjson threshold "$threshold" --arg hash "$hash" \
        --arg to "$to" --arg value "$value" --arg data "$data" \
        --arg selector "$selector" --arg decoded "${decoded:-}" --arg label "$label" \
        --argjson owners "$(live_owners "$safe" | jq -R . | jq -sc .)" '
  {
    network: $net, chainId: $chainId, safe: $safe, nonce: $nonce,
    threshold: $threshold, owners: $owners, safeTxHash: $hash,
    summary: {
      to: $to, toIsBookEntry: $label, value: $value,
      selector: $selector, decoded: (if $decoded == "" then null else $decoded end)
    },
    typedData: {
      types: {
        EIP712Domain: [{name:"chainId",type:"uint256"},{name:"verifyingContract",type:"address"}],
        SafeTx: [
          {name:"to",type:"address"},{name:"value",type:"uint256"},{name:"data",type:"bytes"},
          {name:"operation",type:"uint8"},{name:"safeTxGas",type:"uint256"},
          {name:"baseGas",type:"uint256"},{name:"gasPrice",type:"uint256"},
          {name:"gasToken",type:"address"},{name:"refundReceiver",type:"address"},
          {name:"nonce",type:"uint256"}
        ]
      },
      primaryType: "SafeTx",
      domain: { chainId: $chainId, verifyingContract: $safe },
      message: {
        to: $to, value: $value, data: $data, operation: 0,
        safeTxGas: "0", baseGas: "0", gasPrice: "0",
        gasToken: "0x0000000000000000000000000000000000000000",
        refundReceiver: "0x0000000000000000000000000000000000000000",
        nonce: ($nonce|tostring)
      }
    }
  }' > "$f"

  cmd_show "$f"
  note ""
  note "wrote $f — review it, then each owner runs:"
  note "  $0 sign $f --ledger        # or --account <keystore>"
}

# ---------------------------------------------------------------------------------------------
# show
# ---------------------------------------------------------------------------------------------
cmd_show() {
  local f="${1:?usage: $0 show <file>}"
  jq -r '
    "Safe        \(.safe)  (chain \(.chainId), nonce \(.nonce), threshold \(.threshold))",
    "to          \(.summary.to)   [\(.summary.toIsBookEntry)]",
    "value       \(.summary.value)",
    "selector    \(.summary.selector)   \(.summary.decoded // "(not decoded)")",
    "safeTxHash  \(.safeTxHash)"' "$f" >&2
  local dir base collected
  dir="$(dirname "$f")"; base="$(basename "$f" .json)"
  collected=$(find "$dir" -maxdepth 1 -name "$base.*.sig" 2>/dev/null | wc -l)
  note "signatures  $collected of $(jq -r .threshold "$f") collected"
  find "$dir" -maxdepth 1 -name "$base.*.sig" 2>/dev/null | while read -r s; do
    note "  $(basename "$s" .sig | sed "s/^$base\.//")"
  done
}

# ---------------------------------------------------------------------------------------------
# sign
# ---------------------------------------------------------------------------------------------
cmd_sign() {
  local f="${1:?usage: $0 sign <file> (--ledger | --account <name>)}"; shift
  local -a wallet=(); local hd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ledger)  wallet=(--ledger); shift ;;
      --trezor)  wallet=(--trezor); shift ;;
      --hd-path) hd="$2"; shift 2 ;;
      --account) wallet=(--account "$2" --password "$(cat "$HOME/.secrets/$2.pass")"); shift 2 ;;
      *) die "unknown flag $1" ;;
    esac
  done
  [ "${#wallet[@]}" -gt 0 ] || die "pick a signer: --ledger or --account <name>"
  [ -n "$hd" ] && wallet+=(--mnemonic-derivation-path "$hd")

  local safe hash nonce
  safe="$(jq -r .safe "$f")"; hash="$(jq -r .safeTxHash "$f")"; nonce="$(jq -r .nonce "$f")"

  # 🔴 A stale proposal can never execute: the nonce is inside the signed digest, so if the Safe
  # has moved past it every signature collected here is waste. Checked BEFORE the device is
  # touched, because the whole point of a hardware signer is that a person is standing there.
  local live; live="$(cast call "$safe" 'nonce()(uint256)' --rpc-url "$RPC_URL")"
  [ "$live" = "$nonce" ] || die "proposal is for nonce $nonce but the Safe is at $live — stale, re-propose"

  cmd_show "$f"
  note ""
  case " ${wallet[*]} " in
    *" --ledger "*|*" --trezor "*)
      note "confirm on the device — it will display the SafeTx fields above" ;;
  esac

  local td sig signer
  td="$(mktemp)"; trap 'rm -f "$td"' RETURN
  jq .typedData "$f" > "$td"
  sig="$(cast wallet sign --data --from-file "$td" "${wallet[@]}")"

  # Recover from the SAFE'S OWN digest, not from the typed data we just signed. If cast's EIP-712
  # encoding and the Safe's ever disagreed, this is where it surfaces — as a failure to recover
  # here, rather than as the opaque GS026 "invalid owner provided" after gas is spent.
  local -a owners=(); mapfile -t owners < <(live_owners "$safe")
  signer="$(recover_signer "$hash" "$sig" "${owners[@]}")" || signer=""
  [ -n "$signer" ] \
    || die "signature does not recover to any CURRENT owner of $safe.
  Either this key is not an owner, or cast's EIP-712 encoding no longer matches the Safe's.
  Current owners: ${owners[*]}"

  local out="$(dirname "$f")/$(basename "$f" .json).${signer}.sig"
  printf '%s\n' "$sig" > "$out"
  note ""
  note "signed by $signer"
  note "wrote $out"
}

# The Safe's CURRENT owner set, read off the chain. Deliberately not the address book: the book
# is what the deploy intended, `getOwners` is what the Safe will actually accept, and a signature
# is only useful if it satisfies the second.
live_owners() {
  cast call "$1" 'getOwners()(address[])' --rpc-url "$RPC_URL" \
    | tr -d '[]" ' | tr ',' '\n' | grep -E '^0x[0-9a-fA-F]{40}$'
}

# Recover the address that produced `sig` over the 32-byte digest `hash`, by trying each
# candidate. `cast` has no general recover, and a candidate walk is not a limitation here: the
# only addresses whose signatures the Safe will accept are its owners.
recover_signer() {
  local hash="$1" sig="$2"; shift 2
  local o
  for o in "$@"; do
    if cast wallet verify --no-hash --address "$o" "$hash" "$sig" >/dev/null 2>&1; then
      echo "$o"; return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------------------------
# exec
# ---------------------------------------------------------------------------------------------
cmd_exec() {
  local f="${1:?usage: $0 exec <file> [sig-file ...]}"; shift
  local safe to value data nonce threshold hash
  safe="$(jq -r .safe "$f")"; to="$(jq -r .summary.to "$f")"; value="$(jq -r .summary.value "$f")"
  data="$(jq -r .typedData.message.data "$f")"; nonce="$(jq -r .nonce "$f")"
  threshold="$(jq -r .threshold "$f")"; hash="$(jq -r .safeTxHash "$f")"

  local -a sigfiles=()
  if [ $# -gt 0 ]; then sigfiles=("$@"); else
    while IFS= read -r s; do sigfiles+=("$s"); done \
      < <(find "$(dirname "$f")" -maxdepth 1 -name "$(basename "$f" .json).*.sig" | sort)
  fi
  [ "${#sigfiles[@]}" -ge "$threshold" ] \
    || die "have ${#sigfiles[@]} signature(s), need $threshold"

  # Re-derive the digest from the live Safe. The proposal was written earlier and the Safe may
  # have executed something since; submitting against a moved nonce burns gas for GS026.
  local live_hash live_nonce
  live_nonce="$(cast call "$safe" 'nonce()(uint256)' --rpc-url "$RPC_URL")"
  [ "$live_nonce" = "$nonce" ] || die "Safe is at nonce $live_nonce, proposal is $nonce — stale"
  live_hash="$(cast call "$safe" \
    'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)' \
    "$to" "$value" "$data" 0 0 0 0 "$ZERO" "$ZERO" "$nonce" --rpc-url "$RPC_URL")"
  [ "$live_hash" = "$hash" ] || die "digest drift: file says $hash, Safe says $live_hash"

  # 🔴 Safe's checkNSignatures walks the recovered signers and requires each to be STRICTLY
  # GREATER than the last, so the parts are concatenated in ascending signer-address order — not
  # in filename order and not in the order they were collected.
  local -a owners=(); mapfile -t owners < <(live_owners "$safe")
  local -a pairs=()
  local s sig signer
  for s in "${sigfiles[@]}"; do
    sig="$(tr -d '[:space:]' < "$s")"
    signer="$(recover_signer "$hash" "$sig" "${owners[@]}")" \
      || die "$s does not recover to any CURRENT owner of $safe"
    pairs+=("$(echo "$signer" | lower)|${sig#0x}")
  done

  # A duplicate signer recovers fine and then fails checkNSignatures on the ordering rule, which
  # reports only GS026. Caught here, where the message can say what actually happened.
  local dupes
  dupes="$(printf '%s\n' "${pairs[@]}" | cut -d'|' -f1 | sort | uniq -d)"
  [ -z "$dupes" ] || die "the same owner signed twice: $dupes"

  # 65 bytes each, concatenated in ascending signer order, one 0x on the front.
  local signatures="0x" p
  while IFS= read -r p; do
    signatures="${signatures}${p#*|}"
    note "  signature from ${p%%|*}"
  done < <(printf '%s\n' "${pairs[@]}" | sort)

  local want=$(( (${#pairs[@]} * 65 * 2) + 2 ))
  [ "${#signatures}" -eq "$want" ] \
    || die "assembled signature blob is ${#signatures} chars, expected $want"

  cmd_show "$f"
  note ""
  note "submitting from ${SAFE_TX_SENDER:-choice-v2-deployer}"

  local acct="${SAFE_TX_SENDER:-choice-v2-deployer}"
  # ⛔ An explicit generous --gas-limit, always: eth_estimateGas under-reports on Injective and
  # the shortfall is silent. And no receipt is expected — confirm by reading state.
  cast send "$safe" \
    'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)(bool)' \
    "$to" "$value" "$data" 0 0 0 0 "$ZERO" "$ZERO" "$signatures" \
    --rpc-url "$RPC_URL" --account "$acct" \
    --password "$(cat "$HOME/.secrets/${acct}.pass")" \
    --gas-limit "${SAFE_TX_GAS_LIMIT:-3000000}" 2>&1 | tail -3 || true

  note ""
  note "submitted. Injective may serve no receipt — confirm by reading the Safe's nonce:"
  note "  cast call $safe 'nonce()(uint256)' --rpc-url $RPC_URL   # expect $((nonce + 1))"
}

case "${1:-}" in
  propose) shift; cmd_propose "$@" ;;
  sign)    shift; cmd_sign "$@" ;;
  exec)    shift; cmd_exec "$@" ;;
  show)    shift; cmd_show "$@" ;;
  *) die "usage: $0 {propose|sign|exec|show} ..." ;;
esac
