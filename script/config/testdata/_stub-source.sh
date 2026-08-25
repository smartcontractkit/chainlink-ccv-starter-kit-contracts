#!/usr/bin/env bash
# =============================================================================
#  _stub-source.sh <chainSelector> — TEST DOUBLE for ccip-config-source.sh.
#
#  selftest.sh copies the real scripts into a temp tree and drops this in under the
#  name `ccip-config-source.sh`, so sync-ccip-config.sh invokes it without knowing.
#  Everything above the fetch — the orchestrator, the merge, the bootstrap, the jq
#  library — runs completely unmodified, so the tests exercise shipped code.
#
#  Same contract as the real source: one selector in, one flat JSON object on stdout,
#  non-zero exit plus a stderr reason on failure.
#
#  Exit: 0 OK | 4 NOT_FOUND (no fixture for this selector)
# =============================================================================
set -uo pipefail
SELECTOR="${1:?usage: _stub-source.sh <chainSelector>}"
FIXTURE="${FIXTURE_DIR:?FIXTURE_DIR must be set}/$SELECTOR.json"
[ -f "$FIXTURE" ] || {
    echo "[stub-source] NOT_FOUND: no fixture for selector $SELECTOR" >&2
    exit 4
}
cat "$FIXTURE"
