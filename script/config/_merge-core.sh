#!/usr/bin/env bash
# =============================================================================
#  _merge-core.sh <configFile> <mode:check|sync> <flatSourceFile>
#
#  Compares the CCIP-core fields of a flat source object against config/chains/<name>.json,
#  and in `sync` mode writes them back.
#
#  The owned field set and comparison rules live in core-fields.jq, shared with
#  _bootstrap-chain.sh.
#
#  Owns (overwrites) ONLY the fields core-fields.jq lists — and only when the target
#  already carries the key, and only when the source supplies a non-null value.
#  Preserves every other key byte-for-byte (allowedFinality,
#  storageLocations, resolverSalt, ...).
#  chainSelector is the immutable join GUARD and is never rewritten.
#
#  Writes atomically: temp file in the SAME directory, validated, then mv.
#
#  Exit: 0 clean/wrote | 1 drift (check mode) | 2 guard fail.
# =============================================================================
set -uo pipefail

CONFIG_PATH="${1:?usage: _merge-core.sh <configFile> <mode> <flatSourceFile>}"
MODE="${2:?usage: _merge-core.sh <configFile> <mode> <flatSourceFile>}"
FLAT_PATH="${3:?usage: _merge-core.sh <configFile> <mode> <flatSourceFile>}"

HERE="$(cd "$(dirname "$0")" && pwd)"
jqlib() { jq -L "$HERE" "$@"; }

NAME="$(jq -r '.alias // .name // empty' "$CONFIG_PATH")"
[ -n "$NAME" ] || NAME="$(basename "$CONFIG_PATH" .json)"
ENVIRONMENT="$(jq -r '.environment // "?"' "$FLAT_PATH")"

# ---- GUARD: chainSelector is the immutable join key ----------------------------
SRC_SELECTOR="$(jq -r '.chainSelector | tostring' "$FLAT_PATH")"
CFG_SELECTOR="$(jq -r '.chainSelector | tostring' "$CONFIG_PATH")"
if [ "$SRC_SELECTOR" != "$CFG_SELECTOR" ]; then
    echo "  GUARD FAIL $NAME: source chainSelector $SRC_SELECTOR != config $CFG_SELECTOR"
    exit 2
fi

# A name difference is informational: the join is on chainSelector, never on name.
API_NAME="$(jq -r '.apiName // empty' "$FLAT_PATH")"
if [ -n "$API_NAME" ] && [ "$API_NAME" != "$NAME" ]; then
    echo "  NOTE $NAME: source name '$API_NAME' (join is on chainSelector, not name)"
fi

# ---- compare -------------------------------------------------------------------
# feeTokens is append-only (core-fields.jq unions source with config), so a token
# upstream drops is kept, never counted as drift. Informational NOTE either way:
# to retire one, sweep its accrued fees first, then hand-edit it out of the config.
DROPPED_TOKENS="$(jqlib -r --slurpfile src "$FLAT_PATH" \
    'include "core-fields"; fee_tokens_upstream_dropped(.; $src[0]) | join(", ")' "$CONFIG_PATH")"
if [ -n "$DROPPED_TOKENS" ]; then
    echo "  NOTE $NAME: upstream no longer serves fee token(s): $DROPPED_TOKENS"
    echo "      kept locally (feeTokens is append-only); sweep (SweepFees), then hand-edit to retire"
fi

DIFF_LINES="$(jqlib -r --slurpfile src "$FLAT_PATH" \
    'include "core-fields"; diff_lines(.; $src[0])' "$CONFIG_PATH")"

if [ -z "$DIFF_LINES" ]; then
    echo "  MATCH $NAME [$ENVIRONMENT]: $(jqlib -rn 'include "core-fields"; core | join("+")') agree with source"
    exit 0
fi

echo "  MISMATCH $NAME [$ENVIRONMENT]:"
while IFS= read -r line; do printf '      - %s\n' "$line"; done <<< "$DIFF_LINES"

[ "$MODE" = "sync" ] || exit 1

# ---- write ---------------------------------------------------------------------
CHANGED="$(jqlib -r --slurpfile src "$FLAT_PATH" \
    'include "core-fields"; diffs(.; $src[0]) | map(.key) | join(", ")' "$CONFIG_PATH")"

TMP="$(mktemp "$(dirname "$CONFIG_PATH")/.merge-core.XXXXXX")" || exit 2
trap 'rm -f "$TMP"' EXIT

jqlib --slurpfile src "$FLAT_PATH" --indent 4 'include "core-fields";
    . as $cfg
    | reduce (diffs($cfg; $src[0])[]) as $d (.; .[$d.key] = $d.source)
' "$CONFIG_PATH" > "$TMP" || exit 2

# Refuse to write an empty or unparsable result over a real config.
jq -e . "$TMP" > /dev/null 2>&1 || {
    echo "  ERROR $NAME: refusing to write malformed JSON" >&2
    exit 2
}

mv "$TMP" "$CONFIG_PATH" || {
    echo "  ERROR $NAME: could not move $TMP to $CONFIG_PATH" >&2
    exit 2
}
trap - EXIT
echo "  WROTE $NAME: $CHANGED"
exit 0
