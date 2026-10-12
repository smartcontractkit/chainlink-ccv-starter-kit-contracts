#!/usr/bin/env bash
# =============================================================================
#  selftest.sh — offline tests for the config-sync write and override semantics.
#
#  The real scripts are copied into a temp tree and testdata/_stub-source.sh is dropped
#  in under the name `ccip-config-source.sh`, so the orchestrator, merge, bootstrap and
#  core-fields.jq run unmodified against fixture data. Needs only bash and jq; no
#  network. Never touches the real config/ tree.
#
#  Out of scope: the HTTP layer (404 handling, malformed bodies) - replacing the fetch
#  is the mechanism here, so those need the live API.
#
#  Usage: script/config/selftest.sh
#  Exit:  0 all passed | 1 a test failed | 2 MISSING_TOOL
# =============================================================================
set -uo pipefail

for tool in jq bash; do
    command -v "$tool" > /dev/null 2>&1 || {
        echo "[selftest] MISSING_TOOL: '$tool' not found on PATH" >&2
        exit 2
    }
done

cd "$(dirname "$0")/../.." || exit 2
REPO="$PWD"
PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected [%s] got [%s]\n' "$1" "$3" "$2"
}
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

# ---------------------------------------------------------------- isolated tree
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/script/config" "$TMP/config/chains"
cp "$REPO"/script/config/sync-ccip-config.sh \
    "$REPO"/script/config/_merge-core.sh \
    "$REPO"/script/config/_bootstrap-chain.sh \
    "$REPO"/script/config/_ccip-api.sh \
    "$REPO"/script/config/core-fields.jq "$TMP/script/config/"
# The stub stands in for the real fetch, under the name the orchestrator invokes.
cp "$REPO"/script/config/testdata/_stub-source.sh "$TMP/script/config/ccip-config-source.sh"
cp "$REPO"/config/chains/_template.json "$TMP/config/chains/"

# Fixtures are copied too, so a test may add markers (e.g. an unreachable selector) without
# shipping them in the repo.
cp -R "$REPO"/script/config/testdata "$TMP/testdata"
export FIXTURE_DIR="$TMP/testdata"
: > "$FIXTURE_DIR/5555.unreachable" # the stub exits 5 (API_UNREACHABLE) for this selector
SYNC="$TMP/script/config/sync-ccip-config.sh"
CFG="$TMP/config/chains/fixture.json"
SOURCE_RMN="0xNNNN000000000000000000000000000000000001"
LOCAL_RMN="0xBEEF000000000000000000000000000000000001"

run() { bash "$SYNC" "$@" 2>&1; }
# A content hash is the assertion that matters: "did this command leave the file alone?"
hash_of() { [ -f "$1" ] && shasum "$1" | cut -d' ' -f1 || echo "ABSENT"; }
edit() { jq "$1" "$CFG" > "$TMP/edit.json" && mv "$TMP/edit.json" "$CFG"; }

# ---------------------------------------------------------------- bootstrap
echo "bootstrap: target absent"
out="$(run bootstrap fixture 1111)"
rc=$?
check "exit 0" "$rc" "0"
check "creates the file" "$([ -f "$CFG" ] && echo yes || echo no)" "yes"
check "reports CREATED" "$(echo "$out" | grep -c CREATED)" "1"
check "seeds router" "$(jq -r .router "$CFG")" "0xRRRR000000000000000000000000000000000001"
check "seeds rmn" "$(jq -r .rmn "$CFG")" "$SOURCE_RMN"
check "seeds feeTokens" "$(jq -r '.feeTokens[0]' "$CFG")" "0xTTTT000000000000000000000000000000000001"
check "seeds explorerAddressPath" "$(jq -r .explorerAddressPath "$CFG")" "https://fixture.example/address"
check "chainId normalised to a number" "$(jq -r '.chainId|type' "$CFG")" "number"
check "chainSelector kept a string" "$(jq -r '.chainSelector|type' "$CFG")" "string"
check "no key outside the schema" "$(jq -r 'keys_unsorted|join(",")' "$CFG")" "alias,chainId,chainSelector,router,rmn,feeTokens,explorerAddressPath"
BOOT_HASH="$(hash_of "$CFG")"

echo "bootstrap: target present, agrees"
before="$(hash_of "$CFG")"
out="$(run bootstrap fixture 1111)"
rc=$?
check "exit 0" "$rc" "0"
check "reports OK" "$(echo "$out" | grep -c ' OK ')" "1"
check "file unchanged" "$(hash_of "$CFG")" "$before"

echo "bootstrap: target present, differs — must NOT overwrite"
edit ".rmn = \"$LOCAL_RMN\""
before="$(hash_of "$CFG")"
out="$(run bootstrap fixture 1111)"
rc=$?
check "exit 1" "$rc" "1"
check "reports WARN" "$(echo "$out" | grep -c WARN)" "1"
check "says nothing written" "$(echo "$out" | grep -c 'Nothing written')" "1"
check "file unchanged" "$(hash_of "$CFG")" "$before"
check "local value survives" "$(jq -r .rmn "$CFG")" "$LOCAL_RMN"

echo "bootstrap: wrong selector for an existing alias"
before="$(hash_of "$CFG")"
run bootstrap fixture 9999 > /dev/null 2>&1
rc=$?
check "non-zero exit" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "file unchanged" "$(hash_of "$CFG")" "$before"

echo "bootstrap: source fails — must not leave a partial file"
run bootstrap missing 9999 > /dev/null 2>&1
rc=$?
check "non-zero exit" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "no file created" "$([ -f "$TMP/config/chains/missing.json" ] && echo yes || echo no)" "no"

# ---------------------------------------------------------------- check
echo "check: differs — read-only, must never write"
before="$(hash_of "$CFG")"
out="$(run check fixture)"
rc=$?
check "exit 1" "$rc" "1"
check "reports MISMATCH" "$(echo "$out" | grep -c MISMATCH)" "1"
check "file unchanged" "$(hash_of "$CFG")" "$before"

# ---------------------------------------------------------------- sync
echo "sync: differs — overwrites ONLY the core fields"
cp "$CFG" "$TMP/before-sync.json"
out="$(run sync fixture)"
rc=$?
check "exit 0" "$rc" "0"
check "reports WROTE" "$(echo "$out" | grep -c WROTE)" "1"
check "core field taken from source" "$(jq -r .rmn "$CFG")" "$SOURCE_RMN"
check "every non-core field byte-identical" \
    "$(diff <(jq -S 'del(.rmn)' "$TMP/before-sync.json") <(jq -S 'del(.rmn)' "$CFG") > /dev/null && echo same || echo differs)" \
    "same"
check "sync output byte-identical to a fresh bootstrap (committed files round-trip)" "$(hash_of "$CFG")" "$BOOT_HASH"

echo "chainId: a zero is filled by sync"
edit '.chainId = 0'
out="$(run sync fixture)"
rc=$?
check "exit 0" "$rc" "0"
check "chainId filled" "$(jq -r .chainId "$CFG")" "1111"

echo "chainId: a different non-zero value is a CONFLICT, never written"
edit '.chainId = 9999'
before="$(hash_of "$CFG")"
out="$(run check fixture)"
rc=$?
check "check exits 1" "$rc" "1"
check "check reports CONFLICT" "$(echo "$out" | grep -c 'CONFLICT fixture: chainId: config=9999 source=1111')" "1"
out="$(run sync fixture)"
rc=$?
check "sync exits 1" "$rc" "1"
check "sync reports CONFLICT" "$(echo "$out" | grep -c 'CONFLICT fixture')" "1"
check "file unchanged" "$(hash_of "$CFG")" "$before"
edit '.chainId = 1111'

echo "sync: already agrees"
before="$(hash_of "$CFG")"
out="$(run sync fixture)"
rc=$?
check "exit 0" "$rc" "0"
check "reports MATCH" "$(echo "$out" | grep -c MATCH)" "1"
check "file unchanged" "$(hash_of "$CFG")" "$before"

# ---------------------------------------------------------------- feeTokens append-only
echo "feeTokens: a token the upstream dropped is kept - NOTE, not drift"
edit '.feeTokens += ["0xAAAA000000000000000000000000000000000001"]'
before="$(hash_of "$CFG")"
out="$(run check fixture)"
rc=$?
check "check exits 0" "$rc" "0"
check "check reports the NOTE" "$(echo "$out" | grep -c 'upstream no longer serves fee token')" "1"
check "check still reports MATCH" "$(echo "$out" | grep -c MATCH)" "1"
out="$(run sync fixture)"
rc=$?
check "sync exits 0" "$rc" "0"
check "sync writes nothing" "$(hash_of "$CFG")" "$before"
check "local token kept" "$(jq -r '.feeTokens|length' "$CFG")" "2"

echo "feeTokens: an upstream addition is drift and syncs in as an APPEND (union)"
edit '.feeTokens = ["0xAAAA000000000000000000000000000000000001"]' # source token missing, local-only token kept
out="$(run check fixture)"
rc=$?
check "check exits 1" "$rc" "1"
check "names the field" "$(echo "$out" | grep -c 'feeTokens:')" "1"
out="$(run sync fixture)"
rc=$?
check "sync exits 0" "$rc" "0"
check "union written: local kept, upstream appended" \
    "$(jq -c '.feeTokens | sort' "$CFG")" \
    '["0xAAAA000000000000000000000000000000000001","0xTTTT000000000000000000000000000000000001"]'
# restore agreement with the source for the sections below
edit '.feeTokens = ["0xTTTT000000000000000000000000000000000001"]'

echo "feeTokens: a case-variant duplicate in the config is drift and sync collapses it"
edit '.feeTokens = ["0xTTTT000000000000000000000000000000000001","0xtttt000000000000000000000000000000000001"]'
out="$(run check fixture)"
rc=$?
check "check exits 1" "$rc" "1"
check "names the field" "$(echo "$out" | grep -c 'feeTokens:')" "1"
out="$(run sync fixture)"
rc=$?
check "sync exits 0" "$rc" "0"
check "duplicate collapsed to one entry" "$(jq -r '.feeTokens|length' "$CFG")" "1"
check "first casing kept" "$(jq -r '.feeTokens[0]' "$CFG")" "0xTTTT000000000000000000000000000000000001"

# ---------------------------------------------------------------- explorer path
echo "explorerAddressPath: a changed explorer is drift like any other core field"
edit '.explorerAddressPath = "https://old-explorer.example/address"'
before="$(hash_of "$CFG")"
out="$(run check fixture)"
rc=$?
check "exit 1" "$rc" "1"
check "names the field" "$(echo "$out" | grep -c 'explorerAddressPath')" "1"
check "file unchanged by check" "$(hash_of "$CFG")" "$before"
run sync fixture > /dev/null
check "sync accepts the new explorer" "$(jq -r .explorerAddressPath "$CFG")" "https://fixture.example/address"

echo "explorerAddressPath: a trailing slash is not a difference"
edit '.explorerAddressPath = "https://fixture.example/address/"'
before="$(hash_of "$CFG")"
out="$(run check fixture)"
rc=$?
check "exit 0" "$rc" "0"
check "reports MATCH" "$(echo "$out" | grep -c MATCH)" "1"
check "no rewrite for a cosmetic slash" "$(hash_of "$CFG")" "$before"
edit '.explorerAddressPath = "https://fixture.example/address"'

echo "explorerAddressPath: upstream serving no explorer never wipes the operator's value"
CFG2="$TMP/config/chains/noexplorer.json"
run bootstrap noexplorer 2222 > /dev/null
check "bootstrap leaves it empty when upstream has none" "$(jq -r .explorerAddressPath "$CFG2")" ""
# The operator fills it by hand for a chain the API has no explorer for.
jq '.explorerAddressPath = "https://private-explorer.internal/address"' "$CFG2" > "$TMP/e.json" && mv "$TMP/e.json" "$CFG2"
before="$(hash_of "$CFG2")"
out="$(run check noexplorer)"
rc=$?
check "null source is not drift" "$rc" "0"
out="$(run sync noexplorer)"
check "sync leaves the hand-set value alone" "$(jq -r .explorerAddressPath "$CFG2")" "https://private-explorer.internal/address"
check "file byte-identical after sync" "$(hash_of "$CFG2")" "$before"
rm -f "$CFG2"

echo "check --all: a chain the upstream does not know is SKIPPED, not a failure"
cat > "$TMP/config/chains/localchain.json" <<'JSON'
{"alias":"localchain","chainId":31337,"chainSelector":"424242","router":"0x0000000000000000000000000000000000000001","rmn":"0x0000000000000000000000000000000000000001","feeTokens":[],"explorerAddressPath":""}
JSON
before="$(hash_of "$TMP/config/chains/localchain.json")"
out="$(run check --all)"
rc=$?
check "sweep exits 0" "$rc" "0"
check "reports SKIP for the unknown chain" "$(echo "$out" | grep -c 'SKIP localchain')" "1"
check "still checks the known chain" "$(echo "$out" | grep -cE 'MATCH|MISMATCH')" "1"
check "unknown chain file unchanged" "$(hash_of "$TMP/config/chains/localchain.json")" "$before"

echo "check <name>: naming the unknown chain explicitly IS a failure"
out="$(run check localchain)"
rc=$?
check "named 404 exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"

echo "unknown key: the sync neither reads nor removes it (ConfigLib rejects it at load)"
edit '.stray = "operator data in the wrong file"'
before="$(hash_of "$CFG")"
out="$(run check fixture)"
rc=$?
check "check still reports a match" "$rc" "0"
run sync fixture > /dev/null
check "sync leaves the key in place" "$(jq -r .stray "$CFG")" "operator data in the wrong file"
check "file unchanged" "$(hash_of "$CFG")" "$before"
edit 'del(.stray)'

echo "source unreachable: no verdict, exit 2, nothing written"
CFG3="$TMP/config/chains/unreachable.json"
jq '.alias = "unreachable" | .chainSelector = "5555"' "$CFG" > "$CFG3"
before="$(hash_of "$CFG3")"
out="$(run check unreachable)"
rc=$?
check "named check exits 2" "$rc" "2"
check "reports UNREACHABLE" "$(echo "$out" | grep -c 'UNREACHABLE unreachable')" "1"
out="$(run check --all)"
rc=$?
check "sweep with a clean chain exits 2" "$rc" "2"
check "sweep still reports the clean chain" "$(echo "$out" | grep -c ' MATCH fixture')" "1"
edit ".rmn = \"$LOCAL_RMN\""
out="$(run check --all)"
rc=$?
check "drift outranks a missing verdict in a sweep" "$rc" "1"
edit ".rmn = \"$SOURCE_RMN\""
out="$(run sync unreachable)"
rc=$?
check "sync exits 2" "$rc" "2"
check "sync writes nothing" "$(hash_of "$CFG3")" "$before"
run bootstrap fresh 5555 > /dev/null 2>&1
rc=$?
check "bootstrap exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "bootstrap creates no file" "$([ -f "$TMP/config/chains/fresh.json" ] && echo yes || echo no)" "no"
rm -f "$CFG3"

echo "sync --all: refused"
out="$(run sync --all)"
rc=$?
check "non-zero exit" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "names the reason" "$(echo "$out" | grep -c 'per-chain decision')" "1"

# ---------------------------------------------------------------- hygiene
echo "hygiene"
check "no temp files left in the config dir" \
    "$(find "$TMP/config/chains" -name '.*' -type f | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------- API transport (CCIP_API_BASE)
# The REAL ccip-config-source.sh and the orchestrator's base handling, against a fake `curl`
# first on PATH that records its argv and fails like an unreachable host. Nothing reaches the
# network, and the assertions see exactly what would have been sent.
FAKEBIN="$TMP/fakebin"
CURL_LOG="$TMP/curl.argv"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_LOG"
exit 7
SH
chmod +x "$FAKEBIN/curl"
export CURL_LOG
SRC="$REPO/script/config/ccip-config-source.sh"
src() { PATH="$FAKEBIN:$PATH" bash "$SRC" "$@" 2>&1; }
curl_called() { [ -f "$CURL_LOG" ] && echo yes || echo no; }
curl_has() { grep -cxF -- "$1" "$CURL_LOG" 2> /dev/null || true; }

echo "api: an http:// base is refused before any request"
rm -f "$CURL_LOG"
out="$(CCIP_API_BASE=http://api.ccip.chain.link/v2 src 1111)"
rc=$?
check "source exits 3" "$rc" "3"
check "names BAD_API_BASE" "$(echo "$out" | grep -c BAD_API_BASE)" "1"
check "curl never called" "$(curl_called)" "no"

echo "api: a base hiding another host in userinfo is refused"
rm -f "$CURL_LOG"
out="$(CCIP_API_BASE=https://api.ccip.chain.link@evil.example/v2 src 1111)"
rc=$?
check "source exits 3" "$rc" "3"
check "curl never called" "$(curl_called)" "no"

echo "api: the default base is quiet and the request is pinned to https"
rm -f "$CURL_LOG"
out="$(src 1111)"
rc=$?
check "unreachable fake exits 5" "$rc" "5"
check "no WARN" "$(echo "$out" | grep -c WARN)" "0"
check "requests the default URL" "$(curl_has https://api.ccip.chain.link/v2/chains/1111)" "1"
check "--proto =https" "$(grep -A1 -xF -- --proto "$CURL_LOG" | tail -1)" "=https"
check "--proto-redir =https" "$(grep -A1 -xF -- --proto-redir "$CURL_LOG" | tail -1)" "=https"
check "--tlsv1.2" "$(curl_has --tlsv1.2)" "1"

echo "api: a non-default https base is refused without --allow-custom-api-base"
rm -f "$CURL_LOG"
out="$(CCIP_API_BASE=https://mirror.example:8443/v2/ src 1111)"
rc=$?
check "source exits 3" "$rc" "3"
check "names CUSTOM_API_BASE_REFUSED" "$(echo "$out" | grep -c CUSTOM_API_BASE_REFUSED)" "1"
check "names the flag" "$(echo "$out" | grep -c -- --allow-custom-api-base)" "1"
check "curl never called" "$(curl_called)" "no"

echo "api: with --allow-custom-api-base a non-default https base WARNs and names the host"
rm -f "$CURL_LOG"
out="$(CCIP_API_BASE=https://mirror.example:8443/v2/ src 1111 --allow-custom-api-base)"
rc=$?
check "still runs (fake exits 5)" "$rc" "5"
check "WARN names the base" "$(echo "$out" | grep -c 'WARN.*https://mirror.example:8443/v2')" "1"
check "trailing slash stripped" "$(curl_has https://mirror.example:8443/v2/chains/1111)" "1"

echo "api: a selector that is not 1-20 digits is refused before any request"
for bad in "1111/../admin" "1111?x=1" "" "123456789012345678901"; do
    rm -f "$CURL_LOG"
    out="$(src "$bad")"
    rc=$?
    check "selector '$bad' refused (non-zero exit)" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
    check "selector '$bad': curl never called" "$(curl_called)" "no"
done

echo "api: the orchestrator refuses an http:// base and writes nothing"
before="$(hash_of "$CFG")"
out="$(CCIP_API_BASE=http://api.ccip.chain.link/v2 run check fixture)"
rc=$?
check "check exits 2 (no verdict)" "$rc" "2"
check "names BAD_API_BASE" "$(echo "$out" | grep -c BAD_API_BASE)" "1"
out="$(CCIP_API_BASE=http://api.ccip.chain.link/v2 run sync fixture)"
rc=$?
check "sync exits 2" "$rc" "2"
check "file unchanged" "$(hash_of "$CFG")" "$before"

echo "api: the orchestrator refuses a non-default base without --allow-custom-api-base"
before="$(hash_of "$CFG")"
out="$(CCIP_API_BASE=https://mirror.example/v2 run check fixture)"
rc=$?
check "check exits 2 (no verdict)" "$rc" "2"
check "names CUSTOM_API_BASE_REFUSED" "$(echo "$out" | grep -c CUSTOM_API_BASE_REFUSED)" "1"
out="$(CCIP_API_BASE=https://mirror.example/v2 run sync fixture)"
rc=$?
check "sync exits 2" "$rc" "2"
check "file unchanged" "$(hash_of "$CFG")" "$before"

echo "api: check/sync always print the base they use"
out="$(run check fixture)"
check "default base printed" "$(echo "$out" | grep -cxF 'CCIP API: https://api.ccip.chain.link/v2')" "1"
check "default base not warned about" "$(echo "$out" | grep -c 'CUSTOM CCIP API BASE')" "0"
out="$(CCIP_API_BASE=https://mirror.example/v2 run check fixture --allow-custom-api-base)"
rc=$?
check "allowed override: check runs (exit 0)" "$rc" "0"
check "override printed" "$(echo "$out" | grep -cxF 'CCIP API: https://mirror.example/v2')" "1"
check "override warned about" "$(echo "$out" | grep -c 'WARN: CUSTOM CCIP API BASE https://mirror.example/v2')" "1"
out="$(CCIP_API_BASE=https://mirror.example/v2 run --allow-custom-api-base check fixture)"
rc=$?
check "the flag is accepted before the subcommand too" "$rc" "0"

echo "api: the source rejects an unknown second argument"
rm -f "$CURL_LOG"
out="$(src 1111 --allow-anything)"
rc=$?
check "source exits 3" "$rc" "3"
check "curl never called" "$(curl_called)" "no"

echo "api: discover goes through the same guard and pinned transport"
rm -f "$CURL_LOG"
out="$(CCIP_API_BASE=http://api.ccip.chain.link/v2 PATH="$FAKEBIN:$PATH" bash "$SYNC" discover 2>&1)"
rc=$?
check "http base: exits 2" "$rc" "2"
check "http base: curl never called" "$(curl_called)" "no"
out="$(CCIP_API_BASE=https://mirror.example/v2 PATH="$FAKEBIN:$PATH" bash "$SYNC" discover 2>&1)"
rc=$?
check "custom base without the flag: exits 2" "$rc" "2"
check "custom base without the flag: curl never called" "$(curl_called)" "no"
out="$(PATH="$FAKEBIN:$PATH" bash "$SYNC" discover --env 'testnet&x=1' 2>&1)"
rc=$?
check "bad --env refused" "$rc" "1"
check "bad --env: curl never called" "$(curl_called)" "no"
out="$(PATH="$FAKEBIN:$PATH" bash "$SYNC" discover 2>&1)"
check "no --env: requests the mainnet catalog" "$(curl_has 'https://api.ccip.chain.link/v2/chains?environment=mainnet')" "1"
check "no --env: prints the environment" "$(echo "$out" | grep -c '^Environment: mainnet')" "1"
out="$(PATH="$FAKEBIN:$PATH" bash "$SYNC" discover --env testnet 2>&1)"
check "--env testnet: requests the testnet catalog" "$(curl_has 'https://api.ccip.chain.link/v2/chains?environment=testnet')" "1"
check "--env testnet: prints the environment" "$(echo "$out" | grep -c '^Environment: testnet')" "1"
check "--proto =https" "$(grep -A1 -xF -- --proto "$CURL_LOG" | tail -1)" "=https"
check "--proto-redir =https" "$(grep -A1 -xF -- --proto-redir "$CURL_LOG" | tail -1)" "=https"

# ---------------------------------------------------------------- discover listing
# A fake `curl` that serves a two-chain catalog: 1111 is configured as `fixture`, 2222 is not.
CATALOG_BIN="$TMP/catalogbin"
mkdir -p "$CATALOG_BIN"
cat > "$CATALOG_BIN/curl" <<'SH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
    [ "$1" = "-o" ] && out="$2"
    shift
done
printf '%s' '[{"name":"one","chainFamily":"evm","chainSelector":"1111","chainId":"1"},{"name":"two","chainFamily":"evm","chainSelector":"2222","chainId":"2"}]' > "$out"
printf '200'
SH
chmod +x "$CATALOG_BIN/curl"

echo "discover: lists every API chain with its local status"
out="$(PATH="$CATALOG_BIN:$PATH" bash "$SYNC" discover 2>&1)"
check "configured chain marked" "$(echo "$out" | grep -c 'one .*configured(fixture)')" "1"
check "unconfigured chain listed as available" "$(echo "$out" | grep -c 'two .*available')" "1"

echo "discover: with no chain configs, every API chain is still listed"
ASIDE="$TMP/chains-aside"
mkdir -p "$ASIDE"
find "$TMP/config/chains" -name '*.json' ! -name '_template.json' -exec mv {} "$ASIDE/" \;
out="$(PATH="$CATALOG_BIN:$PATH" bash "$SYNC" discover 2>&1)"
mv "$ASIDE"/*.json "$TMP/config/chains/"
check "both chains listed as available" "$(echo "$out" | grep -c ' available$')" "2"

echo
printf '[selftest] %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
