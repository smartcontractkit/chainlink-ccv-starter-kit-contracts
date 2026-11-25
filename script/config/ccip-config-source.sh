#!/usr/bin/env bash
# ccip-config-source.sh <chainSelector> [--allow-custom-api-base]
#
# The PUBLIC CCIP REST API v2 config source (https://api.ccip.chain.link/v2): the fetch + select
# half of the config-sync seam (real prod/testnet chains).
# GETs the per-chain detail (GET /chains/{selector}) and flattens chainConfig to the single ACTIVE
# (isActive: true) address per contract type, emitting a compact normalized JSON object on stdout
# whose keys mirror the repo's config/chains/<name>.json CCIP-core block. sync-ccip-config.sh then
# merges only those core fields, leaving the identity keys (alias, chainSelector) untouched.
#
# Trimmed to the fields this kit
# carries (router, rmn, feeTokens, explorerAddressPath) plus the CCT-onboarding contracts the API also serves, plus identity fields
# for the SELECTOR-MISMATCH guard (apiName, chainId, chainSelector, chainFamily, environment).
#
# JSON-parsing rule: chainSelector and chainId are served as STRINGS by the API, so jq only ever
# passes them through (never arithmetic) - treated as opaque text. addresses are strings too.
#
# Exit-code contract (stderr becomes the caller's error reason):
#   0  OK (flat JSON on stdout)
#   2  MISSING_TOOL     curl or jq not installed
#   3  BAD_INPUT        CCIP_API_BASE is not an https:// URL, is not the default without
#                       --allow-custom-api-base, or the selector is not 1-20 digits
#   4  NOT_FOUND        HTTP 404 - no chain for this selector
#   5  API_UNREACHABLE  network error / timeout / 5xx (flake, not drift - retry later)
#   6  BAD_BODY         200 but chainConfig lacks an active core entry
#   7  NOT_EVM          the chain exists but its family is not EVM (Solana, Aptos, ...);
#                       this kit is EVM-only (Foundry/cast, 20-byte addresses)
#
# CCIP_API_BASE overrides the API base URL (default https://api.ccip.chain.link/v2). It must be
# https://, and a non-default base is refused unless --allow-custom-api-base is passed, then
# warned about on stderr. The request itself is pinned to https and TLS >= 1.2 (see _ccip-api.sh).
#
# This serves the CCV v2 deployment. Router 1.2.0 multiplexes per destination, so the one
# active chainConfig.router reaches OnRamp 1.6.0 or OnRamp 2.0.0 depending on the lane —
# which is why routers carry no CCIP version. Lane version lives in GET /lanes.
set -euo pipefail

err() { echo "[ccip-config-source] $*" >&2; }

for tool in curl jq; do
    command -v "$tool" > /dev/null 2>&1 || {
        err "MISSING_TOOL: '$tool' not found on PATH (e.g. brew install $tool)"
        exit 2
    }
done

# shellcheck source=script/config/_ccip-api.sh
. "$(dirname "$0")/_ccip-api.sh"

SELECTOR="${1:?usage: ccip-config-source.sh <chainSelector> [--allow-custom-api-base]}"
ALLOW_CUSTOM_API_BASE=0
case "${2:-}" in
    "") ;;
    --allow-custom-api-base) ALLOW_CUSTOM_API_BASE=1 ;;
    *)
        err "BAD_INPUT: unknown arg '$2'"
        exit 3
        ;;
esac
# A chain selector is a uint64: 1-20 decimal digits.
[[ "$SELECTOR" =~ ^[0-9]{1,20}$ ]] || {
    err "BAD_INPUT: chain selector '${SELECTOR}' is not 1-20 decimal digits"
    exit 3
}
BASE_URL="$(ccip_api_base "$ALLOW_CUSTOM_API_BASE")" || exit 3

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

http_code="$(ccip_api_get "${BASE_URL}/chains/${SELECTOR}" "$body_file" 2> /dev/null)" || {
    err "API_UNREACHABLE: could not reach ${BASE_URL}/chains/${SELECTOR} (network error/timeout after retries) - retry later or fix CCIP_API_BASE"
    exit 5
}

case "$http_code" in
    200) ;;
    404)
        # The API body says why, e.g. "Network with chain selector 'X' is not supported".
        api_msg="$(jq -r '.message // empty' "$body_file" 2> /dev/null)"
        err "NOT_FOUND: ${api_msg:-no chain for selector ${SELECTOR}} (sync-ccip-config.sh discover lists valid selectors)"
        exit 4
        ;;
    *)
        err "API_UNREACHABLE: HTTP ${http_code} from ${BASE_URL}/chains/${SELECTOR} (server error/flake, not drift) - retry later"
        exit 5
        ;;
esac

# A 200 with an unparsable body is an upstream problem, not a schema problem: check it
# first so the error names the real cause.
jq -e . "$body_file" > /dev/null 2>&1 || {
    err "BAD_BODY: HTTP 200 from ${BASE_URL}/chains/${SELECTOR} but the body is not valid JSON"
    exit 6
}

# EVM only: the catalog also serves Solana/Aptos/Canton chains. Gate on the family first
# so a non-EVM selector fails with the real reason, not an address-shape error.
family="$(jq -r '(.chain.chainFamily // "EVM") | ascii_downcase' "$body_file")"
if [ "$family" != "evm" ]; then
    err "NOT_EVM: selector ${SELECTOR} is a ${family} chain. This kit is EVM-only; its addresses and tooling (forge/cast) do not apply."
    exit 7
fi

# Key mapping API -> repo schema: rmn (API) -> rmn (repo, the ARMProxy). act(k) REQUIRES an active
# entry for the routing/security core (router, rmn); a chain missing either is not onboardable, so it
# fails loudly rather than write a zero. optAct(k) emits zero for the CCT-onboarding contracts that
# are commonly absent on testnets (the caller logs a WARN, never a silent overwrite of a core field).
jq -c '
  def zero: "0x0000000000000000000000000000000000000000";
  # Refuse malformed addresses from the API before they can reach config/.
  def addr(v): (v | tostring)
    | if test("^0x[0-9a-fA-F]{40}$") then . else error("not an EVM address: \(.)") end;
  # Explorer metadata is nullable at every level (chainMetadata, .explorer, .addressPath).
  # Absent stays NULL, not "": the merge layer skips null source fields, so a chain the
  # API has no explorer for keeps whatever the operator set instead of being wiped.
  def httpUrl(v): if v == null then null else (v | tostring)
    | if test("^https?://[^[:space:]]+$") then sub("/+$"; "")
      else error("not an http(s) URL: \(.)") end end;
  .chainConfig as $c
  | def act(k): (($c[k] // []) | map(select(.isActive == true))
      | if length > 1 then error("\(length) ACTIVE \(k) entries in chainConfig - refusing to pick one: \(map(.address))")
        else (.[0].address // error("no ACTIVE \(k) entry in chainConfig (entries may exist but all are isActive:false)")) end);
    def optAct(k): (($c[k] // []) | (map(select(.isActive == true))[0] // {})
      | (.address // zero));
  {
    apiName: (.chain.name // error("no .chain.name in API body")),
    chainId: (.chain.chainId | tostring),
    chainSelector: (.chain.chainSelector | tostring),
    chainFamily: ((.chain.chainFamily // "EVM") | ascii_downcase),
    environment: (.chain.environment // "testnet"),
    router: addr(act("router")),
    rmn: addr(act("rmn")),
    # The API serves objects (tokenAddress/tokenSymbol/decimals); the repo schema is a flat
    # address list. Absent => empty, which makes the fee scripts a logged no-op.
    feeTokens: [(($c.feeTokens // [])[] | addr(.tokenAddress))],
    # Full URL prefix for address pages, e.g. "https://sepolia.etherscan.io/address".
    explorerAddressPath: httpUrl(.chainMetadata.explorer.addressPath),
    tokenAdminRegistry: addr(optAct("tokenAdminRegistry")),
    registryModuleOwnerCustom: addr(optAct("registryModule")),
    feeQuoter: addr(optAct("feeQuoter"))
  }
' "$body_file" || {
    err "BAD_BODY: could not extract the CCIP-core fields for selector ${SELECTOR}. Either the response is not valid JSON, or chainConfig has no ACTIVE router/rmn entry. See the jq error above."
    exit 6
}