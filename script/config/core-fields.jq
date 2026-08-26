# =============================================================================
#  core-fields.jq — the CCIP-core field set and how to compare it.
#
#  Shared by _merge-core.sh and _bootstrap-chain.sh via `jq -L. --include`, so both
#  agree on which fields are owned and what counts as a difference. Changing the
#  owned set means changing `core` here and nowhere else.
#
#  Load with:  jq -L "$(dirname "$0")" 'include "core-fields"; <filter>'
# =============================================================================

# The fields a config source owns. Everything else in a chain config is operator
# input the source cannot know (versionTag, resolverSalt, storageLocations, ...).
def core: ["router", "rmn", "chainId", "feeTokens", "explorerAddressPath"];

# Per-field equality. Addresses are case-insensitive; feeTokens is an unordered set;
# a trailing slash on the explorer prefix is not a difference; everything else compares
# as opaque text — selectors and chainIds are never coerced to numbers, so a uint64 can
# never lose precision on the comparison path.
def norm(k; v):
    if k == "feeTokens" then [ (v // [])[] | ascii_downcase ] | sort | tostring
    elif k == "router" or k == "rmn" then (v | tostring | ascii_downcase)
    elif k == "explorerAddressPath" then (v | tostring | sub("/+$"; ""))
    else (v | tostring) end;

# Human-readable value: strings bare, everything else as JSON.
def render(v): if (v | type) == "string" then v else (v | tojson) end;

# Core fields the target carries, the source supplies, and the two disagree on.
def diffs($cfg; $src):
    [ core[] | . as $k
      | select(($cfg | has($k)) and ($src[$k] != null))
      | select(norm($k; $src[$k]) != norm($k; $cfg[$k]))
      | {key: $k, config: $cfg[$k], source: $src[$k]} ];

# One "field: config=… source=…" line per difference.
def diff_lines($cfg; $src):
    diffs($cfg; $src)[]
    | "\(.key): config=\(.config | render(.)) source=\(.source | render(.))";

# Core fields present in both the template and the source — i.e. what bootstrap seeds.
def seeded($tpl; $src):
    [ core[] as $k | select(($tpl | has($k)) and ($src[$k] != null)) | $k ];
