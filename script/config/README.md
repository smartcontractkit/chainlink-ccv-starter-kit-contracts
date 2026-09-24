# Config sync

`sync-ccip-config.sh` pulls per-chain CCIP-core values — `router`, `rmn`,
`chainId`, `feeTokens`, `explorerAddressPath` — from the public CCIP REST API into `config/chains/<alias>.json`,
and keeps them verifiable afterwards. That file is Chainlink's reference, and the sync
rewrites those fields alone, so every sync is a diff you can review; the operator's own
values live in `config/operator/`.
`alias` names the file and `chainSelector` is an immutable join guard: a source whose
selector disagrees with the file is refused. There is no per-file source setting: the API
is the single upstream, and a chain it does not serve is simply skipped by sweeps.

Four subcommands; run with no arguments to print the built-in help.

## `discover` — what chains exist

```bash
./script/config/sync-ccip-config.sh discover                # testnet catalog (default)
./script/config/sync-ccip-config.sh discover --env mainnet
```

Lists every chain the API serves — name, family, selector, chainId — and marks the ones
you already have as `configured(<alias>)`. This is where you find the selector for
`bootstrap`.

## `bootstrap` — onboard a new chain

```bash
./script/config/sync-ccip-config.sh bootstrap sepolia 16015286601757825753
```

Creates `config/chains/sepolia.json` from `_template.json` with the core fields filled in
from the API. The file is complete as written, with nothing left to hand-fill.

```
CREATED config/chains/sepolia.json from api: router, rmn, chainId, feeTokens, explorerAddressPath
```

**Bootstrap never overwrites.** Re-running against an existing file prints `OK` when it
agrees with the source, or `WARN` with a field-by-field diff — and writes nothing — when
it does not. That asymmetry is deliberate: an existing file may carry an `rmn` already
baked immutably into a deployed verifier.

## `check` — drift detection, read-only

```bash
./script/config/sync-ccip-config.sh check sepolia
./script/config/sync-ccip-config.sh check --all
```

Compares the core fields against the source and never writes. Exit `0` clean, `1` drift,
`2` could not run — no verdict either way, because a tool is missing or the source was
unreachable. The same shape as
`drift-check.sh`, so one wrapper covers both.
`--all` covers every real chain config, skipping `_template.json`, `*.example.json` and
`zz-scratch-*` test fixtures. With no chain configs at all it prints a `NOTE` saying nothing
was checked and exits `0`.
A chain the API does not know (a local anvil fixture, say) is reported as
`SKIP <alias>: not in upstream` and does not fail the sweep — the upstream is
authoritative about what it serves. Naming such a chain explicitly (`check <alias>`)
still fails, because a direct question deserves the real answer: it may equally be a
typo'd selector.

A fee token kept locally that the upstream no longer serves is a `NOTE`, not drift —
`feeTokens` is append-only (see `sync`), so a local superset is the expected state
until the operator sweeps and retires the token by hand.

## `sync` — accept upstream changes

```bash
./script/config/sync-ccip-config.sh sync sepolia
```

The only writer. Overwrites the core fields and nothing else, atomically (temp file,
validate, rename). A no-drift sync leaves the file byte-identical, so it changes only
when upstream did.

`feeTokens` is the one **append-only** core field: upstream additions merge in, but a
token the upstream drops is kept — removing it from the config would make the fee
scripts skip any balance still accrued in it. Both `check` and `sync` print a `NOTE`
naming such tokens. To retire one: sweep its fees (`SweepFees` reads this config, so
sweep while the token is still listed), then hand-edit it out — the sync will not
re-add a token the upstream no longer serves.

`sync` takes one chain at a time: accepting upstream values is a per-chain decision, and
`rmn` is immutable in a deployed verifier — the config is the only record of what was
deployed, so it should never be bulk-overwritten.

Treat a post-deploy `rmn` drift as something to investigate, not accept: `rmn` is
immutable inside a deployed verifier and has no getter, so the config is the only record
of what was deployed. Syncing over it makes the record lie.

## The intended rhythm

1. **Onboarding**: `discover` → `bootstrap` → declare
   `config/operator/chains/<alias>.json` → deploy.
2. **Ongoing**: `check --all` periodically. On drift, decide: upstream really moved an
   address → `sync` and review the diff; deliberate local divergence → leave it.

## How it is put together

```
sync-ccip-config.sh      the CLI: discover / bootstrap / check / sync
ccip-config-source.sh    fetch + decode: GET /chains/{selector}, pick the isActive
                         entry per contract, refuse anything that is not 0x + 40 hex
_bootstrap-chain.sh      create-if-absent, warn-on-difference
_merge-core.sh           compare, and (sync only) write
core-fields.jq           the owned field set and comparison rules, shared by both
```

The fetch layer is the one untrusted boundary, so validation lives there. Everything
above it is covered by an offline selftest (`make sync-selftest`) that swaps the fetcher for a stub — see `script/config/selftest.sh`.

Debugging: run the source directly to see the raw decoded output —

```bash
./script/config/ccip-config-source.sh 16015286601757825753 | jq .
```

`CCIP_API_BASE` points every command at a different API host.

