#!/usr/bin/env bash
# =============================================================================
#  verify.sh — source-verify the deployed contracts for one chain.
#
#  Constructor arguments come from config/deployments/<alias>.json, recorded by the deploy
#  scripts from the exact values they passed to each constructor. They are NOT derived
#  from config/: `feeAggregator`, `allowlistAdmin` and `storageLocations` are all mutable
#  after a deploy (SetDynamicConfig / UpdateStorageLocations), so config stops describing
#  what was constructed and verification derived from it stops reproducing.
#
#    CREATE2Factory              address[] allowList
#    VersionedVerifierResolver   (none)
#    CommitteeVerifier           (DynamicConfig, string[] storageLocations, address rmn,
#                                 bytes4 versionTag) — one deploy per recorded versionTag
#
#  The record stores each contract's args pre-encoded, so nothing here reconstructs them
#  and no constructor signature is duplicated from the Chainlink contracts.
#
#  Verification only reproduces if the compiler settings match what was deployed, so
#  this always uses the default (release) profile. Never verify a `dev` build.
#
#  Usage (default verifies everything recorded; --only selects one target):
#    script/deploy/verify.sh <chainAlias> [--dry-run]
#    script/deploy/verify.sh <chainAlias> --only factory|resolver|verifiers
#    script/deploy/verify.sh <chainAlias> --only verifier:0x00010001   # one verifier by tag
#
#  Env: ETHERSCAN_API_KEY  (or the per-chain key foundry.toml's [etherscan] resolves)
#       VERIFY_PROVIDER   forge --verifier value; defaults to etherscan. Forge itself
#                         defaults to sourcify, which needs no key but can only ever
#                         partial-match here: bytecode_hash = "none" strips the metadata
#                         hash a full match needs.
#       VERIFY_URL        forge --verifier-url value, for custom/Blockscout-style
#                         explorers. For the default etherscan provider the v2 endpoint
#                         is pinned automatically (also keeps forge single-provider).
#
#  Exit: 0 OK | 1 a verification failed | 2 MISSING_TOOL / bad input
# =============================================================================
set -uo pipefail

for tool in jq forge; do
    command -v "$tool" > /dev/null 2>&1 || {
        echo "[verify] MISSING_TOOL: '$tool' not found on PATH" >&2
        exit 2
    }
done

cd "$(dirname "$0")/../.." || exit 2

ALIAS="${1:?usage: verify.sh <chainAlias> [--dry-run] [--only factory|resolver|verifiers|verifier:<tag>]}"
shift
DRY_RUN=0
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --only)    ONLY="$2";  shift 2 ;;
        *) echo "[verify] unknown arg: $1" >&2; exit 2 ;;
    esac
done

ONLY_TAG=""
case "$ONLY" in
    "" | factory | resolver | verifiers) : ;;
    verifier:0x????????) ONLY_TAG="${ONLY#verifier:}" ;;
    *)
        echo "[verify] unknown --only target: $ONLY" >&2
        echo "         expected factory|resolver|verifiers|verifier:<4-byte tag>" >&2
        exit 2
        ;;
esac

CHAIN_FILE="config/chains/$ALIAS.json"
DEPLOY_FILE="config/deployments/$ALIAS.json"

for f in "$CHAIN_FILE" "$DEPLOY_FILE"; do
    [ -f "$f" ] || { echo "[verify] missing $f" >&2; exit 2; }
done

# Indexing a non-object errors in jq and yields empty output, so every contract would
# report as "not recorded" — a real deployment silently reported as absent. Check the
# shape once, up front, rather than per lookup.
if ! jq -e '(.factory | type == "object") and (.resolver | type == "object") and (.verifiers | type == "array")' \
    "$DEPLOY_FILE" > /dev/null 2>&1; then
    echo "[verify] MALFORMED: $DEPLOY_FILE" >&2
    echo "         .factory and .resolver must be objects holding an address and .verifiers" >&2
    echo "         an array; see config/deployments/_template.json." >&2
    exit 2
fi

CHAIN_ID="$(jq -r '.chainId' "$CHAIN_FILE")"
VERIFY_PROVIDER="${VERIFY_PROVIDER:-etherscan}"
# An explicit --verifier-url keeps forge single-provider: without one it also submits an
# auxiliary, unawaited Sourcify run. So pin the Etherscan v2 endpoint for the default
# provider; VERIFY_URL overrides.
VERIFY_URL="${VERIFY_URL:-}"
if [ -z "$VERIFY_URL" ] && [ "$VERIFY_PROVIDER" = "etherscan" ]; then
    VERIFY_URL="https://api.etherscan.io/v2/api?chainid=$CHAIN_ID"
fi
ZERO="0x0000000000000000000000000000000000000000"

FACTORY_SRC="node_modules/@chainlink/contracts-ccip/contracts/CREATE2Factory.sol:CREATE2Factory"
RESOLVER_SRC="node_modules/@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol:VersionedVerifierResolver"
VERIFIER_SRC="node_modules/@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol:CommitteeVerifier"

# verify_one <label> <contract> <address> <encodedArgs|"-"|"MISSING">
#   Address and encoded args both come from the record, so the two can never disagree.
#   "-" means the contract takes no constructor args; anything empty otherwise is a
#   malformed record — deploys always write encodedArgs, and guessing arguments from
#   mutable config would fail as an opaque bytecode mismatch.
verify_one() {
    local label="$1" contract="$2" addr="$3" encoded="$4"

    if [ -z "$addr" ] || [ "$addr" = "$ZERO" ] || [ "$addr" = "null" ]; then
        echo "  SKIP $label: not recorded in $DEPLOY_FILE"
        return 0
    fi

    local -a args=()
    if [ "$encoded" != "-" ]; then
        if [ "$encoded" = "MISSING" ] || [ -z "$encoded" ] || [ "$encoded" = "0x" ] || [ "$encoded" = "null" ]; then
            echo "  FAIL $label $addr: no encodedArgs in the record — malformed or hand-edited;" >&2
            echo "       redeploy so the deploy script records the constructor arguments." >&2
            return 1
        fi
        args=(--constructor-args "$encoded")
    fi
    [ -n "$VERIFY_URL" ] && args+=(--verifier-url "$VERIFY_URL")

    echo "  $label $addr"
    if [ "$DRY_RUN" = "1" ]; then
        printf '    forge verify-contract %s %s --chain %s --verifier %s' \
            "$addr" "$contract" "$CHAIN_ID" "$VERIFY_PROVIDER"
        printf ' %q' "${args[@]+"${args[@]}"}"
        printf ' --watch\n'
        return 0
    fi
    forge verify-contract "$addr" "$contract" --chain "$CHAIN_ID" \
        --verifier "$VERIFY_PROVIDER" "${args[@]+"${args[@]}"}" --watch || return 1
}

echo "[verify] chain: $ALIAS (chainId $CHAIN_ID)"
echo "[verify] record: $DEPLOY_FILE"
rc=0

if [ -z "$ONLY" ] || [ "$ONLY" = "verifiers" ] || [ -n "$ONLY_TAG" ]; then
    found=""
    while IFS=$'\t' read -r tag vaddr encoded; do
        [ -n "$tag" ] || continue
        [ -n "$ONLY_TAG" ] && [ "$tag" != "$ONLY_TAG" ] && continue
        found="yes"
        verify_one "verifier $tag" "$VERIFIER_SRC" "$vaddr" "$encoded" || rc=1
    done < <(jq -r '.verifiers[]? | [.versionTag, .address, (.encodedArgs // "MISSING")] | @tsv' "$DEPLOY_FILE")
    if [ -z "$found" ]; then
        if [ -n "$ONLY_TAG" ]; then
            echo "[verify] no verifier with versionTag $ONLY_TAG recorded in $DEPLOY_FILE" >&2
            rc=1
        else
            echo "  SKIP verifiers: none recorded in $DEPLOY_FILE"
        fi
    fi
fi

if [ -z "$ONLY" ] || [ "$ONLY" = "resolver" ]; then
    verify_one resolver "$RESOLVER_SRC" "$(jq -r '.resolver.address // empty' "$DEPLOY_FILE")" "-" || rc=1
fi

if [ -z "$ONLY" ] || [ "$ONLY" = "factory" ]; then
    verify_one factory "$FACTORY_SRC" "$(jq -r '.factory.address // empty' "$DEPLOY_FILE")" \
        "$(jq -r '.factory.encodedArgs // "MISSING"' "$DEPLOY_FILE")" || rc=1
fi

exit $rc
