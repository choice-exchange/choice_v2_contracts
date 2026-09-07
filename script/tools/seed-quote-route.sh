#!/usr/bin/env bash
# Open and seed the pool that gives a quote asset its second leg (plan A2), from the encoding
# that 11_SeedQuoteRoutePool.s.sol prints.
#
# The encoding lives in Solidity, where the compiler checks the PoolKey and the action plan; the
# SENDING lives here, because a forge script cannot touch wINJ at all - it is an MTS bank ERC20
# backed by the `0x64` precompile, which has no code for a forked local EVM, so forge reverts on
# so much as a `balanceOf` and `--skip-simulation` does not help. Same reason as
# `seed-bin-pool.sh`; same shape.
#
#   ROUTE_ASSET=0x… script/tools/with-key.sh choice-v2-deployer script/tools/seed-quote-route.sh
#
# 🔑 ONE-SIDED. The pool is opened AT the bottom of the range and funded with wINJ only, because
# the sink only ever SELLS the asset into it - so this can be run by somebody holding none of the
# asset at all. See the script's header for why the price is a decision rather than a discovery.
#
# Idempotent: every step checks the chain first.
set -euo pipefail

RPC="${RPC_URL:-https://k8s.testnet.json-rpc.injective.network}"
PERMIT2="${PERMIT2:-0x000000000022D473030F116dDEE9F6B43aC78BA3}"
: "${PRIVATE_KEY:?run me through script/tools/with-key.sh}" "${ROUTE_ASSET:?set ROUTE_ASSET}"

send() { cast send --async --rpc-url "$RPC" --private-key "$PRIVATE_KEY" "$@"; }
call() { cast call --rpc-url "$RPC" "$@"; }

FROM="$(cast wallet address --private-key "$PRIVATE_KEY")"

echo "==> encoding"
enc="$(ROUTE_ASSET="$ROUTE_ASSET" forge script script/11_SeedQuoteRoutePool.s.sol:SeedQuoteRoutePool \
  --rpc-url "$RPC" --sender "$FROM" 2>/dev/null | sed -n 's/^  SEED_/SEED_/p')"
[ -n "$enc" ] || { echo "the encoder produced nothing - run it alone to see why" >&2; exit 70; }
eval "$enc"
: "${SEED_POOL_MANAGER:?}" "${SEED_POSITION_MANAGER:?}" "${SEED_POOL_ID:?}" "${SEED_PAYLOAD:?}"

echo "    pool  $SEED_POOL_ID"
echo "    from  $FROM"

have="$(call "$SEED_CURRENCY0" 'balanceOf(address)(uint256)' "$FROM" | awk '{print $1}')"
echo "==> funding: wINJ have $have need $SEED_AMOUNT0"
[ "$(echo "$have >= $SEED_AMOUNT0" | bc)" = 1 ] || { echo "not enough wINJ" >&2; exit 65; }

echo "==> allowances (erc20 -> permit2, then permit2 -> position manager)"
cur="$(call "$SEED_CURRENCY0" 'allowance(address,address)(uint256)' "$FROM" "$PERMIT2" | awk '{print $1}')"
if [ "$(echo "$cur < $SEED_AMOUNT0" | bc)" = 1 ]; then
  echo "    erc20 approve  $(send "$SEED_CURRENCY0" 'approve(address,uint256)' "$PERMIT2" \
    0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)"
else
  echo "    erc20 approve  already set"
fi
echo "    permit2 approve  $(send "$PERMIT2" 'approve(address,address,uint160,uint48)' \
  "$SEED_CURRENCY0" "$SEED_POSITION_MANAGER" 1461501637330902918203684832716283019655932542975 281474976710655)"

echo "==> initialize"
live="$(call "$SEED_POOL_MANAGER" 'getSlot0(bytes32)(uint160,int24,uint24,uint24)' "$SEED_POOL_ID" | head -1 | awk '{print $1}')"
if [ "$live" = "0" ]; then
  key="($SEED_CURRENCY0,$SEED_CURRENCY1,0x0000000000000000000000000000000000000000,$SEED_POOL_MANAGER,$SEED_FEE,$SEED_PARAMETERS)"
  echo "    at sqrtPriceX96 $SEED_SQRT_PRICE_X96  $(send --gas-limit 2000000 "$SEED_POOL_MANAGER" \
    'initialize((address,address,address,address,uint24,bytes32),uint160)' "$key" "$SEED_SQRT_PRICE_X96")"
  sleep 6
else
  echo "    already open at sqrtPriceX96 $live"
fi

echo "==> add liquidity"
# 🔴 An explicit gas limit, never an estimate: Injective's `eth_estimateGas` under-reports.
echo "    $(send --gas-limit 3000000 "$SEED_POSITION_MANAGER" 'modifyLiquidities(bytes,uint256)' \
  "$SEED_PAYLOAD" "$(( $(date +%s) + 600 ))")"
sleep 8

echo "==> state after (the receipt is not the check - read the pool)"
call "$SEED_POOL_MANAGER" 'getSlot0(bytes32)(uint160,int24,uint24,uint24)' "$SEED_POOL_ID"
echo "    liquidity $(call "$SEED_POOL_MANAGER" 'getLiquidity(bytes32)(uint128)' "$SEED_POOL_ID")"
echo
echo "==> now register it. Schedule and execute on the timelock:"
echo "    target $SEED_SINK"
echo "    calldata $SEED_SET_ROUTE_CALLDATA"
