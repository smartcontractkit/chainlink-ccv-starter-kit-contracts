# Config sync

`sync-ccip-config.sh` pulls per-chain CCIP-core values — `router`, `rmn`,
`chainId`, `feeTokens`, `explorerAddressPath` — from the public CCIP REST API into `config/chains/<alias>.json`,
and keeps them verifiable afterwards. It never touches the operator-owned fields
(`finalityConfig`, `resolverSalt`, `storageLocations`, roles), and `chainSelector` is an
immutable join guard: a source whose selector disagrees with the file is refused.
There is no per-file source setting: the API is the single upstream, and a chain it
does not serve is simply skipped by sweeps.

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

Creates `config/chains/sepolia.json` from `_template.json` with the core fields
filled in from the API, and lists what is left for you to fill by hand:

```
CREATED config/chains/sepolia.json from api: router, rmn, chainId, feeTokens, explorerAddressPath
    still to fill in: finalityConfig, storageLocations, resolverSalt
```

**Bootstrap never overwrites.** Re-running against an existing file prints `OK` when it
agrees with the source, or `WARN` with a field-by-field diff — and writes nothing — when
it does not. That asymmetry is deliberate: an existing file may carry values chosen on
purpose, including an `rmn` already baked immutably into a deployed verifier.

## `check` — drift detection, read-only

```bash
./script/config/sync-ccip-config.sh check sepolia
./script/config/sync-ccip-config.sh check --all
```

Compares the core fields against the source and never writes. Exit `0` clean, `1` drift,
`2` tooling failure — the same shape as `drift-check.sh`, so it is CI-schedulable.
`--all` covers every real chain config, skipping `_template.json` and `*.example.json`.
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

The only writer. Overwrites the core fields and preserves every other key
byte-for-byte, atomically (temp file, validate, rename).

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

1. **Onboarding**: `discover` → `bootstrap` → hand-fill the operator fields → deploy.
2. **Ongoing**: `check --all` on a schedule. On drift, decide: upstream really moved an
   address → `sync`; deliberate local divergence → leave it.

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

