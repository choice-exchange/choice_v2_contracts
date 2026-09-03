#!/usr/bin/env bash
# Execute one transaction from the Choice v2 Safe.
#
#   safe-exec.sh <to> <calldata> [value]
#
# There is no hosted Safe UI or transaction service for Injective (plan D13), so a Safe
# transaction is assembled, signed and submitted here: read the Safe's nonce, ask the Safe for
# its own EIP-712 digest, collect `threshold` signatures from the signer keystores, and submit.
#
# Signature order matters: Safe's `checkNSignatures` walks the recovered signers and requires
# each to be strictly greater than the last, so the parts are concatenated in ascending signer
# address order, not in the order the keystores are listed.
#
# Signers are read from the address book, so this follows the Safe if its owner set changes.
set -euo pipefail

CHOICE_V2="${CHOICE_V2:-/home/dan/workspace/injective/choice_v2}"
NETWORK="${NETWORK:-injective_testnet}"
RPC_URL="${RPC_URL:-https://k8s.testnet.json-rpc.injective.network}"
BOOK="$CHOICE_V2/contracts/deployments/${NETWORK}.json"

[ $# -ge 2 ] || { echo "usage: $0 <to> <calldata> [value]" >&2; exit 64; }
to="$1"; data="$2"; value="${3:-0}"

safe="$(jq -r .governance.safe "$BOOK")"
threshold="$(jq -r .governance.safeThreshold "$BOOK")"
[ "$safe" != "null" ] || { echo "no Safe in the address book" >&2; exit 65; }

nonce="$(cast call "$safe" 'nonce()(uint256)' --rpc-url "$RPC_URL")"
safeTxHash="$(cast call "$safe" \
  'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)' \
  "$to" "$value" "$data" 0 0 0 0 \
  0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 \
  "$nonce" --rpc-url "$RPC_URL")"

echo "Safe      $safe (nonce $nonce, threshold $threshold)" >&2
echo "to        $to" >&2
echo "safeTxHash $safeTxHash" >&2

# Sign with the first `threshold` signers we hold a keystore for, then order by address.
declare -a pairs=()
for i in 1 2 3; do
  acct="choice-v2-sig${i}"
  [ -r "$HOME/.foundry/keystores/$acct" ] || continue
  [ "${#pairs[@]}" -lt "$threshold" ] || break
  pw="$(cat "$HOME/.secrets/${acct}.pass")"
  addr="$(cast wallet address --account "$acct" --password "$pw")"
  # --no-hash: the Safe's getTransactionHash already IS the EIP-712 digest. Signing it as a
  # message would prefix it with \x19Ethereum Signed Message and recover a different address,
  # which Safe reports only as the opaque GS026 "invalid owner provided".
  sig="$(cast wallet sign --no-hash "$safeTxHash" --account "$acct" --password "$pw")"
  pairs+=("$(echo "$addr" | tr 'A-Z' 'a-z')|$sig")
done

[ "${#pairs[@]}" -eq "$threshold" ] || { echo "only ${#pairs[@]} signers available, need $threshold" >&2; exit 66; }

signatures="0x"
while IFS= read -r p; do
  sig="${p#*|}"
  signatures="${signatures}${sig#0x}"
  echo "  signed by ${p%%|*}" >&2
done < <(printf '%s\n' "${pairs[@]}" | sort)

cast send "$safe" \
  'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)(bool)' \
  "$to" "$value" "$data" 0 0 0 0 \
  0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 \
  "$signatures" \
  --rpc-url "$RPC_URL" --account choice-v2-deployer \
  --password "$(cat "$HOME/.secrets/choice-v2-deployer.pass")" 2>&1 | tail -3 || true

echo "submitted; confirm by reading state (Injective serves no receipt)" >&2
