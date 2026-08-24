#!/usr/bin/env bash
# =============================================================================
#  lane-parity-check.sh — CI wrapper around LaneParityCheck.s.sol.
#
#  Runs the three legs and aggregates:
#     0  clean        — config parity and both chains agree with the lane config
#     1  mismatch     — at least one leg emitted DRIFT_DETECTED
#     2  rpc-unavail  — a leg failed without emitting the marker
#
#  Usage: script/governance/lane-parity-check.sh <laneName> <sourceRpcUrl> <destRpcUrl>
# =============================================================================
set -uo pipefail

LANE="${1:?usage: lane-parity-check.sh <laneName> <sourceRpcUrl> <destRpcUrl>}"
SRC_RPC="${2:?usage: lane-parity-check.sh <laneName> <sourceRpcUrl> <destRpcUrl>}"
DST_RPC="${3:?usage: lane-parity-check.sh <laneName> <sourceRpcUrl> <destRpcUrl>}"

SCRIPT="script/governance/LaneParityCheck.s.sol"
WORST=0

run_leg() {
  local sig="$1"
  shift
  local out
  out="$(forge script "$SCRIPT" --sig "$sig" "$LANE" "$@" 2>&1)"
  local code=$?
  echo "$out"
  [ $code -eq 0 ] && return 0
  if echo "$out" | grep -q "DRIFT_DETECTED"; then
    [ $WORST -lt 1 ] && WORST=1
  else
    WORST=2
  fi
}

run_leg 'runConfig(string)'
run_leg 'runSource(string)' --rpc-url "$SRC_RPC"
run_leg 'runDest(string)' --rpc-url "$DST_RPC"

exit $WORST
