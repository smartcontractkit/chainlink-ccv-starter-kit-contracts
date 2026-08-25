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
    "$REPO"/script/config/core-fields.jq "$TMP/script/config/"
# The stub stands in for the real fetch, under the name the orchestrator invokes.
cp "$REPO"/script/config/testdata/_stub-source.sh "$TMP/script/config/ccip-config-source.sh"
cp "$REPO"/config/chains/_template.json "$TMP/config/chains/"

export FIXTURE_DIR="$REPO/script/config/testdata"
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
check "chainId normalised to a number" "$(jq -r '.chainId|type' "$CFG")" "number"
check "chainSelector kept a string" "$(jq -r '.chainSelector|type' "$CFG")" "string"
check "operator fields left at placeholders" "$(jq -r .versionTag "$CFG")" "0x00000000"

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

echo "sync: already agrees"
before="$(hash_of "$CFG")"
out="$(run sync fixture)"
rc=$?
check "exit 0" "$rc" "0"
check "reports MATCH" "$(echo "$out" | grep -c MATCH)" "1"
check "file unchanged" "$(hash_of "$CFG")" "$before"

echo "check --all: a chain the upstream does not know is SKIPPED, not a failure"
cat > "$TMP/config/chains/localchain.json" <<'JSON'
{"alias":"localchain","chainId":31337,"chainSelector":"424242","router":"0x0000000000000000000000000000000000000001","rmn":"0x0000000000000000000000000000000000000001","versionTag":"0x00010001","finalityConfig":"0x00000001","storageLocations":[],"feeTokens":[],"resolverSalt":"0x0000000000000000000000000000000000000000000000000000000000000001"}
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

echo "sync --all: refused"
out="$(run sync --all)"
rc=$?
check "non-zero exit" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "names the reason" "$(echo "$out" | grep -c 'per-chain decision')" "1"

# ---------------------------------------------------------------- hygiene
echo "hygiene"
check "no temp files left in the config dir" \
    "$(find "$TMP/config/chains" -name '.*' -type f | wc -l | tr -d ' ')" "0"

echo
printf '[selftest] %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
