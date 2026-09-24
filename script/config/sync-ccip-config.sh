#!/usr/bin/env bash
# sync-ccip-config.sh - pull + verify per-chain CCIP-core config from the public CCIP REST
# API v2 into config/chains/<name>.json, the committed reference every script reads.
#
# A selector the API does not serve is SKIPPED by the --all sweep (local chains are not
# in upstream) but is an ERROR when the chain is named explicitly (may be a typo'd
# selector).
#
# The API serves the CCV v2 deployment: chainConfig.router is the same Router the
# OnRamp 2.0.0 uses (Router 1.2.0 multiplexes per destination), and chainConfig.rmn is
# the active ARMProxy. Lane-level CCIP version lives in /lanes, not /chains.
#
# The sync OWNS (overwrites) only the CCIP-core fields the source provides that the target already
# carries: router, rmn, feeTokens, explorerAddressPath (+ chainId refresh). The two other keys are
# identity: alias names the file, and the immutable chainSelector is a GUARD (source.chainSelector
# must equal the file's). A no-drift sync leaves the file byte-identical.
# A core field the source serves as null (explorerAddressPath is nullable) is skipped, not zeroed.
# feeTokens is APPEND-ONLY: upstream additions merge in, but a token upstream drops is kept (and
# NOTEd, not drift) so accrued fees stay sweepable — sweep, then hand-edit to retire it.
#
# JSON-parsing rule: all read/compare/merge goes through jq, which preserves uint64 literals.
# Selectors and chainIds are compared as opaque text, never coerced to numbers.
#
# Usage:
#   sync-ccip-config.sh discover [--env testnet|mainnet]      list the API catalog + local status
#   sync-ccip-config.sh bootstrap <name> <selector>          seed config/chains/<name>.json from the
#                                                             template + API; never overwrites
#   sync-ccip-config.sh check   [<name>|--all]                drift check (no write)
#   sync-ccip-config.sh sync    <name>                        merge + write, one named chain. No
#                                                             `sync --all`: accepting upstream values
#                                                             is a per-chain decision (rmn is immutable
#                                                             in a deployed verifier).
#

# Exit codes: 0 clean | 1 drift-or-error | 2 could not run — no verdict either way (a missing
# tool, or the source was unreachable; stderr names which). Same shape as drift-check.sh.
set -euo pipefail

err() { echo "[sync-ccip-config] $*" >&2; }

for tool in jq curl; do
    command -v "$tool" > /dev/null 2>&1 || {
        err "MISSING_TOOL: '$tool' not found on PATH"
        exit 2
    }
done

cd "$(dirname "$0")/../.."
HERE="script/config"
CHAINS_DIR="config/chains"

# Real per-deployment chain configs only: `_template.json` documents the schema and
# `*.example.json` are illustrative, so neither carries a usable chainSelector; `zz-scratch-*`
# are test fixtures.
list_chains() {
    for f in "$CHAINS_DIR"/*.json; do
        case "$(basename "$f")" in
            _template.json | *.example.json | zz-scratch-*) continue ;;
        esac
        basename "$f" .json
    done
}

# compare_and_maybe_write <file> <mode:check|sync> <flatfile> -> rc 0 clean / 1 drift / 2 guard
compare_and_maybe_write() { bash "$HERE/_merge-core.sh" "$1" "$2" "$3"; }

run_one() { # <name> <mode:check|sync> <sweep:0|1>
    local n="$1" mode="$2" sweep="$3"
    local f="$CHAINS_DIR/$n.json"
    [ -f "$f" ] || {
        err "no $f"
        return 1
    }
    local sel
    sel="$(jq -r '.chainSelector|tostring' "$f")"

    local flatfile errfile srcrc=0
    flatfile="$(mktemp)"
    errfile="$(mktemp)"
    # stdout = flat JSON (-> flatfile); stderr (errors from the source) -> errfile, shown indented
    bash "$HERE/ccip-config-source.sh" "$sel" > "$flatfile" 2> "$errfile" || srcrc=$?
    if [ "$srcrc" -eq 4 ] && [ "$sweep" = "1" ]; then
        # A chain the upstream does not serve cannot drift against it. Named queries
        # still fail on 404: the selector may be a typo.
        echo "  SKIP $n: not in upstream (API has no chain for selector $sel)"
        rm -f "$flatfile" "$errfile"
        return 0
    fi
    [ -s "$errfile" ] && sed 's/^/      ./' "$errfile"
    if [ "$srcrc" -eq 5 ]; then
        # No verdict without the source, which is not drift: 2 lets a scheduled check warn.
        echo "  UNREACHABLE $n: source not reachable, no drift verdict"
        rm -f "$flatfile" "$errfile"
        return 2
    fi
    if [ "$srcrc" -ne 0 ]; then
        rm -f "$flatfile" "$errfile"
        return 1
    fi
    local rc=0
    compare_and_maybe_write "$f" "$mode" "$flatfile" || rc=$?
    rm -f "$flatfile" "$errfile"
    return $rc
}

# bootstrap <alias> <chainSelector>
#
# Seeds config/chains/<alias>.json from _template.json with the CCIP-core values the API
# serves (router, rmn, chainId, feeTokens, explorerAddressPath). NEVER overwrites: if the file already exists
# it only compares and WARNS, so a bootstrap can be re-run safely at any time.
cmd_bootstrap() {
    local n="${1:?usage: bootstrap <chainAlias> <chainSelector>}"
    local sel="${2:?usage: bootstrap <chainAlias> <chainSelector>}"

    local f="$CHAINS_DIR/$n.json"
    local flatfile errfile srcrc=0
    flatfile="$(mktemp)"
    errfile="$(mktemp)"
    bash "$HERE/ccip-config-source.sh" "$sel" > "$flatfile" 2> "$errfile" || srcrc=$?
    [ -s "$errfile" ] && sed 's/^/      ./' "$errfile"
    if [ "$srcrc" -ne 0 ]; then
        rm -f "$flatfile" "$errfile"
        return 1
    fi

    local rc=0
    bash "$HERE/_bootstrap-chain.sh" "$n" "$f" "$CHAINS_DIR/_template.json" "$flatfile" "api" || rc=$?
    rm -f "$flatfile" "$errfile"
    return $rc
}

cmd_discover() {
    local env="testnet"
    while [ $# -gt 0 ]; do
        case "$1" in
            --env)
                env="$2"
                shift 2
                ;;
            *)
                err "discover: unknown arg $1"
                exit 1
                ;;
        esac
    done
    local base="${CCIP_API_BASE:-https://api.ccip.chain.link/v2}"
    local body map
    body="$(mktemp)"
    map="$(mktemp)"
    # EXIT trap with paths expanded at set time: a RETURN trap stays armed after this
    # function returns and would re-fire in main, where these locals no longer exist.
    # shellcheck disable=SC2064
    trap "rm -f '$body' '$map'" EXIT
    local code
    code="$(curl -sS --retry 3 --max-time 30 -o "$body" -w '%{http_code}' "${base}/chains?environment=${env}" 2> /dev/null)" || {
        err "API_UNREACHABLE: ${base}/chains?environment=${env}"
        exit 1
    }
    [ "$code" = "200" ] || {
        err "API_UNREACHABLE: HTTP ${code} from ${base}/chains?environment=${env}"
        exit 1
    }
    for n in $(list_chains); do
        jq -r '[(.chainSelector|tostring), (.alias // .name)] | @tsv' "$CHAINS_DIR/$n.json"
    done > "$map"
    {
        printf 'API NAME\tFAMILY\tSELECTOR\tCHAIN ID\tLOCAL STATUS\n'
        jq -r '(if type=="array" then . else .chains end)[]
            | [.name, (.chainFamily // "?"), (.chainSelector|tostring), (.chainId|tostring)] | @tsv' "$body" |
            awk -F'\t' -v OFS='\t' '
              NR==FNR { nm[$1]=$2; next }
              { st = ($3 in nm) ? "configured("nm[$3]")" : "available"; print $1,$2,$3,$4,st }
            ' "$map" - | sort
    } | column -t -s "$(printf '\t')"
    echo ""
    echo "add a chain: $0 bootstrap <name> <selector>"
}

main() {
    local sub="${1:-}"
    [ $# -gt 0 ] && shift || true
    case "$sub" in
        discover) cmd_discover "$@" ;;
        bootstrap) cmd_bootstrap "$@" ;;
        check | sync)
            local target="--all"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --all)
                        target="--all"
                        shift
                        ;;
                    *)
                        target="$1"
                        shift
                        ;;
                esac
            done
            local names sweep=0 rc=0
            if [ "$sub" = "sync" ] && [ "$target" = "--all" ]; then
                err "sync writes config and is a per-chain decision: name one chain explicitly (the read-only sweep is 'check --all')"
                return 1
            fi
            if [ "$target" = "--all" ]; then
                names="$(list_chains)"
                sweep=1
            else
                names="$target"
            fi
            # An empty sweep is not a clean sweep: say so rather than exiting 0 silently.
            if [ "$sweep" = "1" ] && [ -z "$names" ]; then
                echo "== $sub =="
                echo "  NOTE no chain configs under $CHAINS_DIR: nothing checked"
                return 0
            fi
            echo "== $sub =="
            local one
            for n in $names; do
                one=0
                run_one "$n" "$sub" "$sweep" || one=$?
                # a real verdict outranks "could not run", which outranks clean
                if [ "$one" -eq 2 ]; then
                    [ "$rc" -eq 0 ] && rc=2
                elif [ "$one" -ne 0 ]; then
                    rc=1
                fi
            done
            return $rc
            ;;
        "" | -h | --help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' ;;
        *)
            err "unknown subcommand '$sub' (discover|bootstrap|check|sync)"
            exit 1
            ;;
    esac
}

main "$@"