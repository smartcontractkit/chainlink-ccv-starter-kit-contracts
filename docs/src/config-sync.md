# Syncing chain config

These fields in `config/chains/<alias>.json` come from Chainlink rather than the operator:
`router`, `rmn`, `chainId`, `feeTokens` and `explorerAddressPath`. `script/config/sync-ccip-config.sh` fetches
them from the public CCIP API and keeps them checkable afterwards — prefer these fetched
values over hand-entered ones.

Everything else in the file (`resolverSalt`, `storageLocations`, `finalityConfig`) is
operator-owned. The tool never touches those.

`explorerAddressPath` is nullable upstream. When the API serves no explorer for a chain
the field is skipped entirely — never compared, never written — so a value you set by
hand for a chain Chainlink has no explorer for survives every `sync`.

## Onboarding a new chain

```bash
# 1. find the chain's selector
./script/config/sync-ccip-config.sh discover

# 2. create config/chains/<alias>.json with the Chainlink fields filled in
./script/config/sync-ccip-config.sh bootstrap sepolia 16015286601757825753

# 3. hand-fill the operator fields it lists as "still to fill in", then deploy
```

`bootstrap` never overwrites an existing file — re-running it prints `OK` if the file
agrees with the API, or a field-by-field `WARN` diff if it does not, and writes nothing.

## Staying in sync

```bash
./script/config/sync-ccip-config.sh check --all     # read-only; run on a schedule
./script/config/sync-ccip-config.sh sync sepolia    # accept upstream values, one chain
```

`check` never writes and uses the same exit codes as the governance checks
(**0** clean, **1** drift, **2** couldn't run), so it slots into the same CI shape.

`sync` is deliberately per-chain — there is no `sync --all`. The reason is `rmn`: it is
**immutable inside a deployed verifier and has no getter**, so the config file is the only
record of what was deployed. Treat a post-deploy `rmn` drift as something to investigate,
not something to bulk-accept.

## Details

Field semantics, the `--env mainnet` flag, debugging the raw API output, and how the
pieces fit together are in [Config sync commands](config-sync-reference.md). The tooling
is plain bash + `jq`, covered by an offline selftest (`make test-config`).
