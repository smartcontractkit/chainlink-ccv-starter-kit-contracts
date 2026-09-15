#!/usr/bin/env bash
# =============================================================================
#  _bootstrap-chain.sh <alias> <configPath> <templatePath> <flatSourceFile> <sourceName>
#
#  Seeds config/chains/<alias>.json from the template plus a source's CCIP-core fields.
#  The owned field set and comparison rules live in core-fields.jq, shared with
#  _merge-core.sh.
#
#  NEVER overwrites. If the target does not exist it is created from the template with
#  the core fields filled in from the source, and every field the source cannot know
#  (resolverSalt, storageLocations, ...) left at its template placeholder.
#  If the target already exists, nothing is written: the core fields are compared and any
#  difference is reported as a WARN.
#
#  Never overwrites: an existing file may carry operator-chosen values, including an
#  `rmn` already immutable in a deployed verifier.
#
#  Exit: 0 created or identical | 1 differs (nothing written) | 2 guard fail.
# =============================================================================
set -uo pipefail

ALIAS="${1:?usage: _bootstrap-chain.sh <alias> <config> <template> <flat> <sourceName>}"
CONFIG_PATH="${2:?}"
TEMPLATE_PATH="${3:?}"
FLAT_PATH="${4:?}"
SOURCE_NAME="${5:?}"

HERE="$(cd "$(dirname "$0")" && pwd)"
jqlib() { jq -L "$HERE" "$@"; }

# ---------------------------------------------------------------- existing file
if [ -f "$CONFIG_PATH" ]; then
    SRC_SELECTOR="$(jq -r '.chainSelector | tostring' "$FLAT_PATH")"
    CFG_SELECTOR="$(jq -r '.chainSelector | tostring' "$CONFIG_PATH")"
    if [ "$SRC_SELECTOR" != "$CFG_SELECTOR" ]; then
        echo "  GUARD FAIL $ALIAS: source chainSelector $SRC_SELECTOR != config $CFG_SELECTOR"
        exit 2
    fi

    DIFF_LINES="$(jqlib -r --slurpfile src "$FLAT_PATH" \
        'include "core-fields"; diff_lines(.; $src[0])' "$CONFIG_PATH")"

    if [ -z "$DIFF_LINES" ]; then
        CORE_LIST="$(jqlib -rn 'include "core-fields"; core | join("/")')"
        echo "  OK $ALIAS: $CONFIG_PATH exists and its $CORE_LIST already agree with the $SOURCE_NAME source"
        exit 0
    fi

    echo "  WARN $ALIAS: $CONFIG_PATH exists and DIFFERS from the $SOURCE_NAME source."
    while IFS= read -r line; do printf '      - %s\n' "$line"; done <<< "$DIFF_LINES"
    echo "      Nothing written. Bootstrap never overwrites an existing config."
    echo "      To review:  sync-ccip-config.sh check $ALIAS"
    echo "      To accept:  sync-ccip-config.sh sync  $ALIAS"
    exit 1
fi

# ---------------------------------------------------------------- new file
mkdir -p "$(dirname "$CONFIG_PATH")"
TMP="$(mktemp "$(dirname "$CONFIG_PATH")/.bootstrap.XXXXXX")" || exit 2
trap 'rm -f "$TMP"' EXIT

# chainSelector stays a string: it is a uint64 and exceeds the 2^53 range most JSON
# tooling handles safely. chainId is small, and every hand-written config carries it as a
# number, so normalise it to one rather than leave the source's string form.
jqlib --slurpfile src "$FLAT_PATH" --arg alias "$ALIAS" --indent 2 'include "core-fields";
    $src[0] as $s
    | .alias = $alias
    | .chainSelector = ($s.chainSelector | tostring)
    | reduce (seeded(.; $s)[]) as $k (.;
        .[$k] = (if $k == "chainId" then ($s[$k] | tonumber) else $s[$k] end))
' "$TEMPLATE_PATH" > "$TMP" || exit 2

jq -e . "$TMP" > /dev/null 2>&1 || {
    echo "  ERROR $ALIAS: refusing to write malformed JSON" >&2
    exit 2
}

SEEDED="$(jqlib -r --slurpfile src "$FLAT_PATH" \
    'include "core-fields"; seeded(.; $src[0]) | join(", ")' "$TEMPLATE_PATH")"

# Anything still at a template placeholder is an operator input the source cannot supply.
PLACEHOLDERS="$(jq -r '
    to_entries
    | map(select(.value == "" or .value == 0 or .value == []
                 or (.value | type == "string" and test("^0x0+$"))))
    | map(.key) | join(", ")
' "$TMP")"

mv "$TMP" "$CONFIG_PATH" || {
    echo "  ERROR could not move $TMP to $CONFIG_PATH" >&2
    exit 2
}
trap - EXIT

echo "  CREATED $CONFIG_PATH from $SOURCE_NAME: $SEEDED"
[ -n "$PLACEHOLDERS" ] && echo "      still to fill in: $PLACEHOLDERS"
exit 0
