#!/usr/bin/env bash
# Open and seed the bin pool that 06_SeedBinPool.s.sol encodes.
#
# The encoding lives in Solidity, where the compiler checks it; the SENDING lives here, because
# a forge script cannot touch wINJ or USDT at all. Both are MTS bank ERC20s backed by the `0x64`
# precompile, which has no code for a forked local EVM to execute, so forge reverts with "call
# to non-contract address" on so much as a `balanceOf` - and `--skip-simulation` does not help,
# since forge still runs the script body locally to collect the calls. `cast` goes straight at
# the node, which has the precompiles. Plan §1 item 6.
#
#   script/tools/with-key.sh choice-v2-deployer script/tools/seed-bin-pool.sh
#
# Idempotent: every step checks the chain first, so a run that dies part way can be re-run.
# Ran against testnet 1439 on 2026-09-05; the pool it opened is in the address book under
# `pools[]` with its three transaction hashes.
set -euo pipefail

RPC="${RPC_URL:-https://k8s.testnet.json-rpc.injective.network}"
PERMIT2="${PERMIT2:-0x000000000022D473030F116dDEE9F6B43aC78BA3}"
: "${PRIVATE_KEY:?run me through script/tools/with-key.sh}"

# 🔴 `--async`, and no receipt lookup. Injective's RPC accepts a transaction and then answers
# the very next `eth_getTransactionReceipt` for its hash with null, so `cast send` (which waits
# for one) exits non-zero on transactions that LANDED - and inside a command substitution that
# failure does not even trip `set -e`. Measured here on 2026-09-05: all four seed transactions
# reported "server returned a null response" and all four are `ok` on the explorer. So: send,
# print the hash, and check the CHAIN at the end rather than believing any receipt.
send() { cast send --async --rpc-url "$RPC" --private-key "$PRIVATE_KEY" "$@"; }
call() { cast call --rpc-url "$RPC" "$@"; }

echo "==> encoding the seed"
enc="$(forge script script/06_SeedBinPool.s.sol:SeedBinPool --rpc-url "$RPC" 2>/dev/null | sed -n 's/^  SEED_/SEED_/p')"
[ -n "$enc" ] || { echo "the encoder produced nothing - run it alone to see why" >&2; exit 70; }
eval "$enc"
: "${SEED_POOL_MANAGER:?}" "${SEED_POSITION_MANAGER:?}" "${SEED_POOL_ID:?}" "${SEED_PAYLOAD:?}"

FROM="$(cast wallet address --private-key "$PRIVATE_KEY")"
echo "    pool  $SEED_POOL_ID"
echo "    from  $FROM"

echo "==> funding"
for pair in "$SEED_CURRENCY0:$SEED_AMOUNT0" "$SEED_CURRENCY1:$SEED_AMOUNT1"; do
  token="${pair%%:*}"; need="${pair##*:}"
  have="$(call "$token" 'balanceOf(address)(uint256)' "$FROM" | awk '{print $1}')"
  echo "    $token  have $have  need $need"
  [ "$(echo "$have >= $need" | bc)" = 1 ] || { echo "not enough $token" >&2; exit 65; }
done

echo "==> allowances"
# Two hops: the ERC20 allowance goes to Permit2, then Permit2 is told which spender may use it.
# Approving the position manager on the ERC20 alone looks right on an explorer and moves nothing.
for token in "$SEED_CURRENCY0" "$SEED_CURRENCY1"; do
  cur="$(call "$token" 'allowance(address,address)(uint256)' "$FROM" "$PERMIT2" | awk '{print $1}')"
  if [ "$(echo "$cur < $SEED_AMOUNT0" | bc)" = 1 ]; then
    echo "    erc20 approve $token -> permit2  $(send "$token" 'approve(address,uint256)' "$PERMIT2" \
      0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)"
  else
    echo "    erc20 approve $token -> permit2  already set"
  fi
  echo "    permit2 approve $token -> position manager  $(send "$PERMIT2" \
    'approve(address,address,uint160,uint48)' "$token" "$SEED_POSITION_MANAGER" \
    1461501637330902918203684832716283019655932542975 281474976710655)"
done

echo "==> initialize"
live="$(call "$SEED_POOL_MANAGER" 'getSlot0(bytes32)(uint24,uint24,uint24)' "$SEED_POOL_ID" | head -1 | awk '{print $1}')"
if [ "$live" = "0" ]; then
  key="($SEED_CURRENCY0,$SEED_CURRENCY1,0x0000000000000000000000000000000000000000,$SEED_POOL_MANAGER,$SEED_FEE,$SEED_PARAMETERS)"
  echo "    at active id $SEED_ACTIVE_ID  $(send "$SEED_POOL_MANAGER" \
    'initialize((address,address,address,address,uint24,bytes32),uint24)' "$key" "$SEED_ACTIVE_ID")"
else
  echo "    already open at active id $live"
fi

echo "==> add liquidity"
# 🔴 An explicit gas limit, not an estimate: Injective's `eth_estimateGas` under-reports, and a
# 156,069-gas estimate reverting on a call that needed more is already on the record.
echo "    $(send --gas-limit 3000000 "$SEED_POSITION_MANAGER" 'modifyLiquidities(bytes,uint256)' \
  "$SEED_PAYLOAD" "$(( $(date +%s) + 600 ))")"

echo "==> state after"
# The receipt is not the check. Read the pool back.
cast call --rpc-url "$RPC" "$SEED_POOL_MANAGER" 'getSlot0(bytes32)(uint24,uint24,uint24)' "$SEED_POOL_ID"
for d in -2 -1 0 1 2; do
  id=$(( SEED_ACTIVE_ID + d ))
  echo "    bin $id  $(call "$SEED_POOL_MANAGER" 'getBin(bytes32,uint24)(uint128,uint128)' "$SEED_POOL_ID" "$id" | tr '\n' ' ')"
done
