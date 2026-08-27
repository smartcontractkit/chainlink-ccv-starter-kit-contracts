#!/usr/bin/env bash
# =============================================================================
#  drift-check.sh — CI-schedulable wrapper around DriftCheck.s.sol.
#
#  Distinct exit codes:
#     0  clean        — on-chain state matches declared config
#     1  drift        — at least one mismatch (script emitted DRIFT_DETECTED)
#     2  rpc-unavail  — could not reach the RPC / the check failed for other reasons
#
#  Usage: script/governance/drift-check.sh <chainAlias> <rpcUrl>
# =============================================================================
set -uo pipefail

ALIAS="${1:?usage: drift-check.sh <chainAlias> <rpcUrl>}"
RPC_URL="${2:?usage: drift-check.sh <chainAlias> <rpcUrl>}"

OUT="$(forge script script/governance/DriftCheck.s.sol \
  --sig 'run(string)' "$ALIAS" \
  --rpc-url "$RPC_URL" 2>&1)"
CODE=$?

echo "$OUT"

if [ $CODE -eq 0 ]; then
  exit 0
fi

# Non-zero forge exit: distinguish declared drift from an RPC/other failure.
if echo "$OUT" | grep -q "DRIFT_DETECTED"; then
  exit 1
fi

exit 2
