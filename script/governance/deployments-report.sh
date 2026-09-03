#!/usr/bin/env bash
# =============================================================================
#  deployments-report.sh — generate docs/src/deployments.md from the records.
#
#  Reads config/deployments/<alias>.json + config/chains/<alias>.json and emits a
#  per-network table of deployed addresses and the constructor arguments each contract
#  was actually built with. Verifiers are listed per versionTag: a chain can run several
#  at once.
#
#  Also asserts the cross-chain invariant while it is here: the resolver must be at
#  the SAME address on every chain. A divergence is flagged in the output and sets
#  a non-zero exit, so this doubles as a CI check.
#
#  Explorer links come from the optional `explorerAddressPath` field (synced from the API).
#
#  Usage: script/governance/deployments-report.sh [--check]
#           (no args)  write docs/src/deployments.md
#           --check    print to stdout, write nothing; exit 1 if the file is stale
#
#  Exit: 0 OK | 1 resolver divergence or (with --check) stale output
#        2 MISSING_TOOL, bad arguments, a malformed record, or a refused write
# =============================================================================
set -uo pipefail

command -v jq > /dev/null 2>&1 || {
    echo "[deployments-report] MISSING_TOOL: jq not found on PATH" >&2
    exit 2
}

cd "$(dirname "$0")/../.." || exit 2
DEPLOYMENTS_DIR="config/deployments"
CHAINS_DIR="config/chains"
OUT="docs/src/deployments.md"
ZERO="0x0000000000000000000000000000000000000000"
# Marks a render with no records; matched again on the write path. Keep in step with the
# empty-case text in render().
EMPTY_MARKER="No deployments recorded yet"

usage() {
    echo "Usage: script/governance/deployments-report.sh [--check]"
    echo "  (no args)  write $OUT"
    echo "  --check    print to stdout, write nothing; exit 1 if the file is stale"
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
                echo "[deployments-report] BAD_ARGS: unknown argument '$1'" >&2
                usage >&2
                exit 2
                ;;
        esac
        ;;
    *)
        echo "[deployments-report] BAD_ARGS: expected at most one argument, got $#" >&2
        usage >&2
        exit 2
        ;;
esac

# Real per-deployment records only: templates and examples carry no usable address.
aliases() {
    for f in "$DEPLOYMENTS_DIR"/*.json; do
        [ -e "$f" ] || continue
        # zz-scratch-* is the repo-wide fixture marker.
        # The test suite writes records under it: ConfigLib.writeDeployment targets the real
        # directory, so fixtures land here.
        case "$(basename "$f")" in _template.json | *.example.json | zz-scratch-*) continue ;; esac
        n="$(basename "$f" .json)"
        # A deployment record is only meaningful alongside its chain config. Say so on
        # stderr rather than dropping it: a silently short report reads as complete.
        if [ -f "$CHAINS_DIR/$n.json" ]; then
            echo "$n"
        else
            echo "[deployments-report] SKIP $n: no $CHAINS_DIR/$n.json for this deployment record" >&2
        fi
    done
}

# Indexing a non-object errors in jq and yields empty output, which would render a page of
# blank cells and still exit 0. Check every record's shape once, up front.
for n in $(aliases); do
    if ! jq -e '(.factory | type == "object") and (.resolver | type == "object") and (.verifiers | type == "array")' \
        "$DEPLOYMENTS_DIR/$n.json" > /dev/null 2>&1; then
        echo "[deployments-report] MALFORMED: $DEPLOYMENTS_DIR/$n.json" >&2
        echo "                     .factory and .resolver must be objects holding an address and" >&2
        echo "                     .verifiers an array; see config/deployments/_template.json." >&2
        exit 2
    fi
done

# link <alias> <address> -> markdown link if the chain declares an explorerAddressPath, else code
# The field is a FULL URL prefix from the CCIP API (chainMetadata.explorer.addressPath),
# e.g. "https://sepolia.etherscan.io/address" — the address is appended directly.
link() {
    local base
    [ -n "$2" ] && [ "$2" != "$ZERO" ] || {
        printf 'not recorded'
        return 0
    }
    base="$(jq -r '.explorerAddressPath // empty' "$CHAINS_DIR/$1.json")"
    if [ -n "$base" ]; then
        printf '[`%s`](%s/%s)' "$2" "${base%/}" "$2"
    else
        printf '`%s`' "$2"
    fi
}

addr() { jq -r --arg k "$2" '.[$k].address // "'"$ZERO"'"' "$DEPLOYMENTS_DIR/$1.json"; }

render() {
    local names resolvers=""
    names="$(aliases)"

    echo "# Deployed addresses"
    echo
    if [ -z "$names" ]; then
        echo "No deployments recorded yet. Deploy scripts write \`config/deployments/<alias>.json\`;"
        echo "re-run \`script/governance/deployments-report.sh\` to regenerate this page."
        return 0
    fi

    echo "> Generated by \`script/governance/deployments-report.sh\` from \`config/\`."
    echo "> Do not edit by hand — re-run \`script/governance/deployments-report.sh\` after a deploy."
    echo

    echo "## Contracts"
    echo
    echo "Verifiers are listed as \`versionTag\` → address: a chain can run several at once"
    echo "(each lane pins the one serving it), and the tag is an immutable constructor argument."
    echo
    echo "| Chain | Factory | Resolver | Verifiers (versionTag → address) |"
    echo "|---|---|---|---|"
    for n in $names; do
        local f r v_cell
        f="$(addr "$n" factory)"
        r="$(addr "$n" resolver)"
        resolvers="$resolvers$([ "$r" != "$ZERO" ] && printf '%s' "$r")"$'\n'
        v_cell=""
        while IFS=$'\t' read -r tag vaddr; do
            [ -n "$tag" ] || continue
            v_cell="$v_cell${v_cell:+<br>}\`$tag\` → $(link "$n" "$vaddr")"
        done < <(jq -r '.verifiers[]? | "\(.versionTag)\t\(.address)"' "$DEPLOYMENTS_DIR/$n.json")
        [ -n "$v_cell" ] || v_cell="not recorded"
        printf '| `%s` | %s | %s | %s |\n' "$n" "$(link "$n" "$f")" "$(link "$n" "$r")" "$v_cell"
    done
    echo

    echo "## Deploy-time constructor arguments"
    echo
    echo "Recorded by the deploy scripts from the exact values each constructor received, so"
    echo "these stay correct after config changes. \`rmn\` is immutable per verifier; the"
    echo "CREATE2 salt fixes the resolver's address (the resolver itself takes no"
    echo "constructor arguments)."
    echo
    echo "| Chain | Chain ID | Selector | Verifier rmn (per tag) | Resolver: CREATE2 salt |"
    echo "|---|---:|---|---|---|"
    for n in $names; do
        local rec="$DEPLOYMENTS_DIR/$n.json"
        local chain_id selector salt rmn_cell
        chain_id="$(jq -r '.chainId' "$CHAINS_DIR/$n.json")"
        selector="$(jq -r '.chainSelector' "$CHAINS_DIR/$n.json")"
        salt="$(jq -r '.resolver.salt // "not recorded"' "$rec")"
        rmn_cell=""
        while IFS=$'\t' read -r tag rmn; do
            [ -n "$tag" ] || continue
            rmn_cell="$rmn_cell${rmn_cell:+<br>}\`$tag\` → \`$rmn\`"
        done < <(jq -r '.verifiers[]? | "\(.versionTag)\t\(.args.rmn // "not recorded")"' "$rec")
        [ -n "$rmn_cell" ] || rmn_cell="not recorded"
        printf '| `%s` | %s | `%s` | %s | `%s` |\n' "$n" "$chain_id" "$selector" "$rmn_cell" "$salt"
    done
    echo

    echo "### Verifier storage locations at deploy time"
    echo
    for n in $names; do
        local any=""
        while IFS=$'\t' read -r tag locs; do
            [ -n "$tag" ] || continue
            any="yes"
            printf -- '- `%s` `%s`: %s\n' "$n" "$tag" "$locs"
        done < <(jq -r '.verifiers[]? | [.versionTag, ((.args.storageLocations // []) | if length == 0 then "none recorded" else map("`" + . + "`") | join(", ") end)] | @tsv' \
            "$DEPLOYMENTS_DIR/$n.json")
        [ -n "$any" ] || printf -- '- `%s`: no verifiers recorded\n' "$n"
    done
    echo

    # The invariant: one resolver address everywhere. Equal salts are necessary but not
    # sufficient — the factory address and initcode must match too — so compare the
    # recorded addresses themselves. Blank entries are records without a resolver yet,
    # normal between `bootstrap` and `deploy-resolver`; drop them before counting or they
    # collapse into one "distinct" value and read as parity. Reported separately below.
    local recorded distinct missing total
    recorded="$(printf '%s' "$resolvers" | sed '/^$/d')"
    total="$(printf '%s' "$resolvers" | grep -c '' 2> /dev/null || true)"
    distinct="$(printf '%s' "$recorded" | sort -u | grep -c '' 2> /dev/null || true)"
    missing=$((total - $(printf '%s' "$recorded" | grep -c '' 2> /dev/null || true)))
    echo "## Resolver address parity"
    echo
    if [ "$distinct" = "0" ]; then
        echo "No resolver address is recorded on any chain yet, so there is nothing to compare."
    elif [ "$distinct" = "1" ]; then
        echo "✅ The resolver is at the same address on every chain that has one recorded:"
        echo
        printf '    %s\n' "$(printf '%s' "$recorded" | sort -u)"
    else
        echo "❌ **The resolver address DIVERGES across chains.** Integrators hardcode one"
        echo "resolver address, so this must be fixed before the lanes are usable. Distinct"
        echo "addresses recorded:"
        echo
        printf '%s' "$recorded" | sort -u | sed 's/^/    /'
    fi
    if [ "$missing" -gt 0 ]; then
        echo
        echo "> $missing of $total chains have no resolver address recorded, so they are not"
        echo "> covered by the statement above. Expected between \`bootstrap\` and"
        echo "> \`deploy-resolver\`; investigate otherwise."
    fi
    return 0
}

body="$(render)"
status=0
printf '%s' "$body" | grep -q "DIVERGES" && status=1

if [ "$MODE" = check ]; then
    printf '%s\n' "$body"
    # An absent output file is stale, not clean — the doc is committed, so its absence
    # is a finding in exactly the way a mismatch is.
    if [ ! -f "$OUT" ]; then
        echo "[deployments-report] STALE: $OUT does not exist; run script/governance/deployments-report.sh" >&2
        exit 1
    fi
    if ! diff -q <(printf '%s\n' "$body") "$OUT" > /dev/null 2>&1; then
        echo "[deployments-report] STALE: $OUT does not match config/; re-run script/governance/deployments-report.sh" >&2
        exit 1
    fi
    exit $status
fi

# A clone has no config/deployments/*.json — the directory is gitignored — so a first
# `make deployments-doc` there would replace a populated page with the empty placeholder
# and exit 0. Refuse instead: emptying the record is a decision, not a side effect.
if printf '%s' "$body" | grep -q "$EMPTY_MARKER" \
    && [ -f "$OUT" ] && ! grep -q "$EMPTY_MARKER" "$OUT"; then
    echo "[deployments-report] REFUSING to write: no deployment records found, but $OUT" >&2
    echo "  holds generated content. config/deployments/ is gitignored, so this is what a" >&2
    echo "  fresh clone looks like. Delete $OUT first if you really mean to reset it." >&2
    exit 2
fi

mkdir -p "$(dirname "$OUT")"
printf '%s\n' "$body" > "$OUT"
echo "[deployments-report] wrote $OUT"
exit $status
