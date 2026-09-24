# =============================================================================
#  core-fields.jq — the CCIP-core field set and how to compare it.
#
#  Shared by _merge-core.sh and _bootstrap-chain.sh via `jq -L. --include`, so both
#  agree on which fields are owned and what counts as a difference. Changing the
#  owned set means changing `core` here and nowhere else.
#
#  Load with:  jq -L "$(dirname "$0")" 'include "core-fields"; <filter>'
# =============================================================================

# The fields a config source owns. Everything else in a chain config is identity:
# `alias` names the file and `chainSelector` is the join guard.
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

# Case-insensitive dedupe: first occurrence wins and keeps its casing; order preserved.
def dedupe_case_insensitive:
    reduce .[] as $t ({seen: {}, out: []};
        ($t | ascii_downcase) as $k
        | if .seen[$k] then . else .seen[$k] = true | .out += [$t] end)
    | .out;

# feeTokens is APPEND-ONLY: the effective source is config + source, deduped case-
# insensitively (first occurrence wins), so a token upstream drops is never removed
# locally — it stays sweepable until the operator sweeps and hand-edits it out.
# Upstream additions diff; a case-variant duplicate inside the config diffs too, and sync collapses it.
def with_fee_union($cfg; $src):
    if ($cfg | has("feeTokens")) and ($src.feeTokens != null)
    then $src + {feeTokens: ((($cfg.feeTokens // []) + $src.feeTokens) | dedupe_case_insensitive)}
    else $src end;

# Core fields the target carries, the source supplies, and the two disagree on.
def diffs($cfg; $src):
    with_fee_union($cfg; $src) as $s
    | [ core[] | . as $k
      | select(($cfg | has($k)) and ($s[$k] != null))
      | select(norm($k; $s[$k]) != norm($k; $cfg[$k]))
      | {key: $k, config: $cfg[$k], source: $s[$k]} ];

# One "field: config=… source=…" line per difference.
def diff_lines($cfg; $src):
    diffs($cfg; $src)[]
    | "\(.key): config=\(.config | render(.)) source=\(.source | render(.))";

# Core fields present in both the template and the source — i.e. what bootstrap seeds.
def seeded($tpl; $src):
    [ core[] as $k | select(($tpl | has($k)) and ($src[$k] != null)) | $k ];

# Fee tokens the config carries that the source no longer serves. Informational only
# (append-only keeps them): the NOTE tells the operator to sweep, then hand-edit to retire.
def fee_tokens_upstream_dropped($cfg; $src):
    if ($cfg | has("feeTokens")) and ($src.feeTokens != null)
    then (($src.feeTokens // []) | map(ascii_downcase)) as $kept
       | [ (($cfg.feeTokens // []) | dedupe_case_insensitive)[] | select((ascii_downcase) as $t | ($kept | index($t)) == null) ]
    else [] end;
