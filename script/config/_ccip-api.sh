#!/usr/bin/env bash
# =============================================================================
#  _ccip-api.sh — SOURCED, not run. The transport to the CCIP REST API, shared by
#  ccip-config-source.sh (GET /chains/{selector}) and sync-ccip-config.sh discover
#  (GET /chains?environment=...).
#
#  ccip_api_base accepts only https://host[:port][/path] (no credentials, query or
#  fragment). A base other than the default is refused unless the caller passes
#  allowCustom=1 (the --allow-custom-api-base flag), and WARNs on stderr when allowed.
#  ccip_api_get pins every request to https (redirects included) and TLS >= 1.2.
# =============================================================================

CCIP_API_DEFAULT_BASE="https://api.ccip.chain.link/v2"

# ccip_api_base <allowCustom:0|1> -> the validated base URL (trailing slashes stripped) on stdout.
# rc 3 with a stderr reason when CCIP_API_BASE is not an acceptable https URL, or is not the
# default and allowCustom is not 1.
ccip_api_base() {
    local allow_custom="${1:-0}"
    local base="${CCIP_API_BASE:-$CCIP_API_DEFAULT_BASE}"
    while [ "${base%/}" != "$base" ]; do base="${base%/}"; done
    local re='^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$'
    if ! [[ "$base" =~ $re ]]; then
        echo "[ccip-api] BAD_API_BASE: CCIP_API_BASE='${CCIP_API_BASE:-}' is not an https:// URL of the form https://host[:port][/path] (no credentials, query or fragment). The API is the source of router and rmn, so cleartext or odd URLs are refused." >&2
        return 3
    fi
    if [ "$base" != "$CCIP_API_DEFAULT_BASE" ]; then
        if [ "$allow_custom" != "1" ]; then
            echo "[ccip-api] CUSTOM_API_BASE_REFUSED: CCIP_API_BASE='${base}' is not the default API (${CCIP_API_DEFAULT_BASE}). router and rmn come from this API: pass --allow-custom-api-base (make <target> ALLOW_CUSTOM_API_BASE=true) to use it, or unset CCIP_API_BASE." >&2
            return 3
        fi
        echo "[ccip-api] WARN: CUSTOM CCIP API BASE ${base} (default ${CCIP_API_DEFAULT_BASE}): router and rmn come from it." >&2
    fi
    printf '%s\n' "$base"
}

# ccip_api_get <url> <bodyFile> -> HTTP status code on stdout; curl's exit code otherwise.
ccip_api_get() {
    curl -sS --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --max-time 30 \
        -o "$2" -w '%{http_code}' "$1"
}
