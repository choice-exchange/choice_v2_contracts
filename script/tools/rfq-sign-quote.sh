#!/usr/bin/env bash
# Sign one RfqSettlement quote - the whole of what a market maker's quote server has to do.
#
#   RFQ=0x… TAKER=0x… TOKEN_IN=0x… AMOUNT_IN=… TOKEN_OUT=0x… AMOUNT_OUT=… \
#     script/tools/rfq-sign-quote.sh <keystore-account>
#
# Prints one JSON object: the quote, the signature, and the quote as the tuple `fill` takes, so
#
#   cast send $RFQ 'fill((address,address,uint256,address,uint256,uint256,uint256),bytes,address)' \
#     "$(jq -r .tuple q.json)" "$(jq -r .signature q.json)" $RECIPIENT
#
# Amounts are in each token's smallest unit. TAKER=0x0000000000000000000000000000000000000000
# makes the quote fillable by whoever holds it. NONCE defaults to a random 64-bit value (nonces
# are unordered, so a server can hand out many at once); DEADLINE to now + TTL seconds (60).
#
# The quote is plain EIP-712 - domain `RfqSettlement` / `1` / chain id / the contract - so any
# EIP-712 library signs it. This one signs from a Foundry keystore with the password read from
# ~/.secrets, as `with-key.sh` does, so the key is never in the environment or on a command line.
set -euo pipefail

account="${1:?usage: $0 <keystore-account>}"
RPC="${RPC_URL:-https://sentry.evm-rpc.injective.network}"
: "${RFQ:?}" "${TAKER:?}" "${TOKEN_IN:?}" "${AMOUNT_IN:?}" "${TOKEN_OUT:?}" "${AMOUNT_OUT:?}"
CHAIN_ID="${CHAIN_ID:-$(cast chain-id --rpc-url "$RPC")}"
NONCE="${NONCE:-$(od -An -N8 -tu8 /dev/urandom | tr -d ' ')}"
DEADLINE="${DEADLINE:-$(( $(date +%s) + ${TTL:-60} ))}"

passfile="${HOME}/.secrets/${account}.pass"
[ -r "$passfile" ] || { echo "no password file at $passfile" >&2; exit 66; }

typed="$(mktemp)"
trap 'rm -f "$typed"' EXIT
cat > "$typed" <<JSON
{
  "types": {
    "EIP712Domain": [
      {"name": "name", "type": "string"},
      {"name": "version", "type": "string"},
      {"name": "chainId", "type": "uint256"},
      {"name": "verifyingContract", "type": "address"}
    ],
    "Quote": [
      {"name": "taker", "type": "address"},
      {"name": "tokenIn", "type": "address"},
      {"name": "amountIn", "type": "uint256"},
      {"name": "tokenOut", "type": "address"},
      {"name": "amountOut", "type": "uint256"},
      {"name": "nonce", "type": "uint256"},
      {"name": "deadline", "type": "uint256"}
    ]
  },
  "primaryType": "Quote",
  "domain": {"name": "RfqSettlement", "version": "1", "chainId": "$CHAIN_ID", "verifyingContract": "$RFQ"},
  "message": {
    "taker": "$TAKER", "tokenIn": "$TOKEN_IN", "amountIn": "$AMOUNT_IN",
    "tokenOut": "$TOKEN_OUT", "amountOut": "$AMOUNT_OUT", "nonce": "$NONCE", "deadline": "$DEADLINE"
  }
}
JSON

signer="$(cast wallet address --account "$account" --password-file "$passfile")"
sig="$(cast wallet sign --data --from-file "$typed" --account "$account" --password-file "$passfile")"

# Two checks before the quote leaves: the signature recovers to this key under standard EIP-712,
# and this key is the one the contract will check against. A rotated signer otherwise produces
# quotes that look fine and revert BadSignature at the taker.
cast wallet verify --data --from-file "$typed" --address "$signer" "$sig" > /dev/null
live="$(cast call --rpc-url "$RPC" "$RFQ" 'signer()(address)')"
if [ "$(echo "$live" | tr '[:upper:]' '[:lower:]')" != "$(echo "$signer" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "refusing: $RFQ checks quotes against $live, not $signer" >&2
  exit 65
fi

printf '{"quote":{"taker":"%s","tokenIn":"%s","amountIn":"%s","tokenOut":"%s","amountOut":"%s","nonce":"%s","deadline":"%s"},"signature":"%s","tuple":"(%s,%s,%s,%s,%s,%s,%s)"}\n' \
  "$TAKER" "$TOKEN_IN" "$AMOUNT_IN" "$TOKEN_OUT" "$AMOUNT_OUT" "$NONCE" "$DEADLINE" "$sig" \
  "$TAKER" "$TOKEN_IN" "$AMOUNT_IN" "$TOKEN_OUT" "$AMOUNT_OUT" "$NONCE" "$DEADLINE"
