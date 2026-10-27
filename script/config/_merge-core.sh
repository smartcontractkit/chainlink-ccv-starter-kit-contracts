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
#  Every other key is left as it is: alias is the file's identity, chainSelector the
#  immutable join GUARD. ConfigLib rejects any key outside the schema at load.
#
#  Writes atomically: temp file in the SAME directory, validated, then mv.
#
#  GATE: router and rmn are the security-relevant core fields, so `sync` refuses to change
#  either without an explicit override, and writes nothing at all when refused:
#    - rmn: when a verifier recorded in config/deployments/<name>.json was built on the
#      current value. rmn is an immutable constructor argument with no getter, so the new
#      value would silently split the next deploy-verifier from its siblings.
#      Override: ALLOW_RMN_CHANGE=true.
#    - router: always. Lanes with no router override inherit it on the next configure run.
#      Override: ALLOW_ROUTER_CHANGE=true.
#  `check` stays read-only and reports a gated change as PENDING with the override it needs.
#
#  Exit: 0 clean/wrote | 1 drift (check mode) or a gated change refused (sync) | 2 guard fail.
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

# ---- GATE: router and rmn need an explicit override ---------------------------
CHANGED_KEYS="$(jqlib -r --slurpfile src "$FLAT_PATH" \
    'include "core-fields"; diffs(.; $src[0])[] | .key' "$CONFIG_PATH")"
DEPLOYMENT_PATH="$(dirname "$CONFIG_PATH")/../deployments/$(basename "$CONFIG_PATH")"
REFUSED=0

# gate <field> <override var> <why> <what to do>
gate() {
    local field="$1" var="$2" why="$3" todo="$4"
    if [ "$MODE" != "sync" ]; then
        echo "  PENDING $NAME: the $field change needs $var=true to sync - $why"
        return
    fi
    case "${!var:-}" in
        true | 1)
            echo "  OVERRIDE $NAME: $field change accepted ($var) - $why"
            ;;
        *)
            echo "  REFUSED $NAME: $field change - $why"
            echo "      $todo"
            REFUSED=1
            ;;
    esac
}

if grep -qx rmn <<< "$CHANGED_KEYS"; then
    BOUND_TAGS=""
    if [ -f "$DEPLOYMENT_PATH" ]; then
        BOUND_TAGS="$(jq -r --arg old "$(jq -r '.rmn' "$CONFIG_PATH")" \
            '[.verifiers[]? | select((.args.rmn // "" | ascii_downcase) == ($old | ascii_downcase))
              | .versionTag] | join(", ")' "$DEPLOYMENT_PATH")" || {
            echo "  ERROR $NAME: could not read $DEPLOYMENT_PATH" >&2
            exit 2
        }
    fi
    if [ -n "$BOUND_TAGS" ]; then
        gate rmn ALLOW_RMN_CHANGE \
            "verifier(s) $BOUND_TAGS recorded in $DEPLOYMENT_PATH were built on the current rmn, which is IMMUTABLE" \
            "Confirm the new ARMProxy with Chainlink. If it is genuine, re-run with ALLOW_RMN_CHANGE=true and redeploy those verifiers: they keep the old RMN, make drift flags each one until then, and a new deploy-verifier would build on the new one. If it is not, leave the config as it is."
    fi
fi

if grep -qx router <<< "$CHANGED_KEYS"; then
    gate router ALLOW_ROUTER_CHANGE \
        "every lane without a router override inherits it on the next make apply-remote-config" \
        "Confirm the new router with Chainlink. If it is genuine, re-run with ALLOW_ROUTER_CHANGE=true, then re-run make apply-remote-config for those lanes and check make parity."
fi

[ "$MODE" = "sync" ] || exit 1

if [ "$REFUSED" -eq 1 ]; then
    echo "  Nothing written for $NAME: a gated change was refused (no field was synced)"
    exit 1
fi

# ---- write ---------------------------------------------------------------------
CHANGED="$(jqlib -r --slurpfile src "$FLAT_PATH" \
    'include "core-fields"; diffs(.; $src[0]) | map(.key) | join(", ")' "$CONFIG_PATH")"

TMP="$(mktemp "$(dirname "$CONFIG_PATH")/.merge-core.XXXXXX")" || exit 2
trap 'rm -f "$TMP"' EXIT

jqlib --slurpfile src "$FLAT_PATH" --indent 2 'include "core-fields";
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
