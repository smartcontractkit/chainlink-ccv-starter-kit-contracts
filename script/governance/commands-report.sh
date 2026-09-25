#!/usr/bin/env bash
# =============================================================================
#  commands-report.sh — generate docs/src/commands.md from the Makefile.
#
#  Parses the Makefile's own `# ---- <section> ----` headers and `## ` help lines
#  (the same convention `make help` reads) and emits one table per section:
#  Target | Purpose | Caller | Mode | Key inputs.
#
#  Caller and Mode come from a compact tag suffix appended to the `## ` help line of
#  the operational (deploy / configure / ownership / fees / governance) targets:
#
#    some-target: ## human purpose text | caller=<role> | mode=<eoa|safe|eoa,safe|n/a>
#
#  A target without the tag suffix (build/test/fmt/lint/install/discover/sync/...) is
#  rendered with Caller/Mode "n/a" and just its plain help text as Purpose. `make help`
#  still works on a tagged line — it just prints the tag suffix along with the rest.
#
#  Usage: script/governance/commands-report.sh [--check]
#           (no args)  write docs/src/commands.md
#           --check    print to stdout, write nothing; exit 1 if the file is stale or a
#                      target is missing its `## ` description
#
#  Exit: 0 OK | 1 (with --check) stale output or a target missing `## `
#        2 BAD_ARGS or a refused write
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/../.." || exit 2
MAKEFILE="Makefile"
OUT="docs/src/commands.md"

usage() {
    echo "Usage: script/governance/commands-report.sh [--check]"
    echo "  (no args)  write $OUT"
    echo "  --check    print to stdout, write nothing; exit 1 if the file is stale"
    echo "             or any make target is missing a '## ' description"
}

# Writing is the no-argument default, so an unrecognised argument must be rejected
# rather than defaulted: this script's write path overwrites a committed doc.
case "$#" in
    0) MODE="write" ;;
    1)
        case "$1" in
            --check) MODE="check" ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                echo "[commands-report] BAD_ARGS: unknown argument '$1'" >&2
                usage >&2
                exit 2
                ;;
        esac
        ;;
    *)
        echo "[commands-report] BAD_ARGS: expected at most one argument, got $#" >&2
        usage >&2
        exit 2
        ;;
esac

[ -f "$MAKEFILE" ] || {
    echo "[commands-report] $MAKEFILE not found" >&2
    exit 2
}

# Any real target ("name:" at column 0, not a variable assignment or a `define`) that
# has no '## ' help text. A silently undocumented target is a defect in the same way a
# stale doc is - catch it here rather than let `make help` quietly omit it.
undocumented="$(grep -E '^[A-Za-z][A-Za-z0-9_.-]*:' "$MAKEFILE" | grep -v '##' || true)"

# section \t target \t help  (help still carries the "| caller=.. | mode=.." suffix,
# split out below). The catch-all section for targets above the first header keeps the
# same label the plan for this doc uses: "build-dev-utility".
rows="$(awk '
    # Only a header naming one of the target groups this doc knows about starts a new
    # section; a stray "# ---- ... ----" comment elsewhere (e.g. above the run-script
    # define, which documents macros, not a target group) leaves the section alone.
    function is_known_group(k) {
        return k == "chain-config" || k == "deploy" || k == "configure" || \
               k == "ownership" || k == "fees" || k == "governance"
    }
    /^# ---- / {
        line = $0
        sub(/^# ---- /, "", line)
        sub(/ ----[[:space:]]*$/, "", line)
        key = line
        sub(/[:(].*/, "", key)
        gsub(/^[ \t]+|[ \t]+$/, "", key)
        gsub(/[ \t]+/, "-", key)
        key = tolower(key)
        if (is_known_group(key)) section = key
        next
    }
    /^[A-Za-z][A-Za-z0-9_.-]*:.*##/ {
        if (section == "") section = "build-dev-utility"
        line = $0
        colon = index(line, ":")
        target = substr(line, 1, colon - 1)
        hashpos = index(line, "##")
        help = substr(line, hashpos + 2)
        gsub(/^[ \t]+/, "", help)
        printf "%s\t%s\t%s\n", section, target, help
    }
' "$MAKEFILE")"

# recipe_vars <target> -> space-separated $(VAR) references in that target's recipe
# body (every line up to, but not including, the next target or EOF). Restricted to the
# small set of variables the recipes actually read, in a fixed, meaningful order.
#
# A target that delegates to the shared run-script/run-lane-script defines (CHAIN/LANE/TAG
# stay visible - they are passed as literal call arguments) never mentions RPC_URL,
# OUTPUT_MODE or SAFE_ADDRESS directly: those live inside run-script-core. Recipes that
# call either define always require RPC_URL, and SAFE_ADDRESS conditionally (mode=SAFE
# only - see the Mode column), so add both when that delegation is detected.
recipe_vars() {
    local target="$1" body
    body="$(awk -v t="$target" '
        $0 ~ "^" t ":" { grab = 1; next }
        grab && /^[A-Za-z][A-Za-z0-9_.-]*:/ { grab = 0 }
        grab { print }
    ' "$MAKEFILE")"
    local out="" var
    for var in CHAIN LANE TAG SELECTOR TARGET RPC_URL SOURCE_RPC DEST_RPC; do
        if printf '%s' "$body" | grep -q "\$($var)"; then
            out="$out${out:+, }$var"
        fi
    done
    if printf '%s' "$body" | grep -qE 'call run-(lane-)?script,'; then
        printf '%s' "$out" | grep -q 'RPC_URL' || out="$out${out:+, }RPC_URL"
        out="$out${out:+, }SAFE_ADDRESS (mode=safe only)"
    fi
    printf '%s' "$out"
}

# section_title <key> -> the heading rendered above that section's table. Portable
# capitalize-first-letter (no \U / \u: BSD sed and awk toupper() don't do per-char
# case folding the same way, so this stays in plain shell).
section_title() {
    case "$1" in
        build-dev-utility) printf 'Build & dev utility' ;;
        chain-config) printf 'Chain config' ;;
        *)
            local first rest
            first="$(printf '%s' "$1" | cut -c1 | tr '[:lower:]' '[:upper:]')"
            rest="$(printf '%s' "$1" | cut -c2-)"
            printf '%s%s' "$first" "$rest"
            ;;
    esac
}

render() {
    echo "# Command reference"
    echo
    echo "> Generated by \`make commands-doc\` from the \`Makefile\`."
    echo "> Do not edit by hand — re-run \`make commands-doc\` after changing a target."
    echo
    echo "Caller and Mode come from the \`| caller=.. | mode=..\` tag on the target's \`## \`"
    echo "help line in the Makefile (n/a where a target carries no tag, e.g. build/test"
    echo "utilities). Mode lists which \`OUTPUT_MODE\` values the target accepts; n/a means"
    echo "the target does not broadcast, or broadcasts unconditionally as EOA."
    echo

    local prev_section=""
    while IFS=$'\t' read -r section target help; do
        [ -n "$target" ] || continue
        if [ "$section" != "$prev_section" ]; then
            [ -z "$prev_section" ] || echo
            echo "## $(section_title "$section")"
            echo
            echo "| Target | Purpose | Caller | Mode | Key inputs |"
            echo "|---|---|---|---|---|"
            prev_section="$section"
        fi

        local purpose="$help" caller="n/a" mode="n/a"
        case "$help" in
            *"| caller="*)
                caller="$(printf '%s' "$help" | sed -n 's/.*| caller=\([^|]*\).*/\1/p')"
                caller="$(printf '%s' "$caller" | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//')"
                purpose="$(printf '%s' "$help" | sed 's/ | caller=.*//')"
                ;;
        esac
        case "$help" in
            *"| mode="*)
                mode="$(printf '%s' "$help" | sed -n 's/.*| mode=\([^|]*\).*/\1/p')"
                mode="$(printf '%s' "$mode" | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//')"
                ;;
        esac

        local inputs
        inputs="$(recipe_vars "$target")"
        [ -n "$inputs" ] || inputs="none"

        # A raw '|' in the help text (e.g. "ONLY=factory|resolver|verifier:<tag>") would
        # otherwise split the markdown table row into extra, misaligned columns.
        purpose="$(printf '%s' "$purpose" | sed 's/|/\\|/g')"

        printf '| `make %s` | %s | %s | %s | %s |\n' \
            "$target" "$purpose" "$caller" "$mode" "$inputs"
    done <<< "$rows"
}

body="$(render)"

if [ -n "$undocumented" ]; then
    echo "[commands-report] MISSING_HELP: the following targets have no '## ' description:" >&2
    printf '%s\n' "$undocumented" | sed 's/^/  /' >&2
    [ "$MODE" = check ] && exit 1
    exit 2
fi

if [ "$MODE" = check ]; then
    printf '%s\n' "$body"
    if [ ! -f "$OUT" ]; then
        echo "[commands-report] STALE: $OUT does not exist; run script/governance/commands-report.sh" >&2
        exit 1
    fi
    if ! diff -q <(printf '%s\n' "$body") "$OUT" > /dev/null 2>&1; then
        echo "[commands-report] STALE: $OUT does not match the Makefile; re-run script/governance/commands-report.sh" >&2
        exit 1
    fi
    exit 0
fi

mkdir -p "$(dirname "$OUT")"
printf '%s\n' "$body" > "$OUT"
echo "[commands-report] wrote $OUT"
