#!/usr/bin/env bash
# Run a command with PRIVATE_KEY exported from a Foundry keystore, decrypted at call time.
#
# The key exists only in this process's environment for the life of the command: it is never
# written to a file, never echoed, and never lands in shell history because the password is
# read from ~/.secrets rather than passed on the command line.
#
#   script/tools/with-key.sh choice-v2-deployer forge script ... --broadcast --slow
#
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <keystore-account> <command...>" >&2
  exit 64
fi

account="$1"; shift
passfile="${HOME}/.secrets/${account}.pass"
[ -r "$passfile" ] || { echo "no password file at $passfile" >&2; exit 66; }

# `set +x` guards against the caller having tracing on: a decrypted key must never reach a log.
set +x
PRIVATE_KEY="$(CAST_UNSAFE_PASSWORD="$(cat "$passfile")" cast wallet decrypt-keystore "$account" \
  | sed -n 's/.*0x\([0-9a-fA-F]\{64\}\).*/0x\1/p')"
[ -n "$PRIVATE_KEY" ] || { echo "failed to decrypt keystore $account" >&2; exit 70; }
export PRIVATE_KEY

exec "$@"
