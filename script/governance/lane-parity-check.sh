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
SOURCE_RPC="${2:?usage: lane-parity-check.sh <laneName> <sourceRpcUrl> <destRpcUrl>}"
DEST_RPC="${3:?usage: lane-parity-check.sh <laneName> <sourceRpcUrl> <destRpcUrl>}"

SCRIPT="script/governance/LaneParityCheck.s.sol"
WORST=0

run_leg() {
  local banner="$1" sig="$2"
  shift 2
  echo "== [lane-parity-check] $banner =="
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

run_leg "leg 1/3 runConfig: config files only, no RPC" 'runConfig(string)'
run_leg "leg 2/3 runSource: source chain via SOURCE_RPC" 'runSource(string)' --rpc-url "$SOURCE_RPC"
run_leg "leg 3/3 runDest: dest chain via DEST_RPC" 'runDest(string)' --rpc-url "$DEST_RPC"

exit $WORST
