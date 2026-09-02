# Governance checks

Each check answers a different question. None replaces another.

| check | question | scope |
|---|---|---|
| `DriftCheck` | does chain X match X's own config? | one chain, one RPC |
| `LaneParityCheck` | do the two halves of a lane agree with each other? | one lane, two RPCs |
| `sync-ccip-config.sh check` | does my config still match Chainlink's API? | all chains, no RPC — see [Syncing chain config](config-sync.md) |
| `deployments-report.sh --check` | is the deployed-addresses page current, and the resolver identical everywhere? | all records, no RPC |

All of them share one exit-code convention — **0** clean, **1** a real finding, **2** the
check could not run — so a single CI shape covers them.

A lane whose halves disagree **passes drift on both sides** while every message fails on
first use. That gap is exactly what parity exists to close.

## Drift check

```bash
make drift                                              # defaults to sepolia
make drift CHAIN=base_sepolia RPC_URL=$BASE_SEPOLIA_RPC_URL
script/governance/drift-check.sh sepolia $SEPOLIA_RPC_URL
```

Reconciles live on-chain state against `config/chains`, `config/roles` and
`config/lanes` — role holders, fee aggregators, storage locations, finality config,
resolver implementations, and per-lane remote config.

Exit codes: **0** clean, **1** drift, **2** RPC unreachable or another failure.

The distinction between 1 and 2 matters for CI. On drift, the script logs a
`DRIFT_DETECTED` marker and reverts; the wrapper greps for that marker. Anything that
reverts *without* it — an unreachable RPC, a missing deployment record — falls through to
2 rather than being reported as real drift.

Drift is direction-aware. Running against a chain that is only ever a lane *source* will
not check signer sets, because those live on the destination. If a chain's inbound
configuration never seems to be checked, the reverse lane file is probably missing.

### What drift cannot see

`rmn` is stored as `IRMN internal immutable i_rmn` with no getter. It cannot be read back,
so it is the one configured value with **zero drift coverage**. A wrong value sits there
indefinitely looking correct — and since it is immutable, correcting it means redeploying
the verifier. Verify it before deploying.

## Lane parity check

```bash
script/governance/lane-parity-check.sh sepolia-to-base_sepolia $SEPOLIA_RPC_URL $BASE_SEPOLIA_RPC_URL
```

Runs three legs and aggregates the worst result:

1. **`runConfig`** — config against config, no RPC. Selector agreement, lane `versionTag`
   recorded on both chains, `resolverSalt` identical, recorded resolver addresses identical,
   nothing left unrecorded, `gasForVerification` non-zero.
2. **`runSource`** — on the source chain: the outbound implementation for the destination
   selector, and the remote chain config.
3. **`runDest`** — on the destination chain: the inbound implementation for the **lane's**
   `versionTag`, that the destination verifier's own immutable tag matches, and the signer
   set keyed by the source selector.

Same exit codes and the same `DRIFT_DETECTED` marker as drift, so one CI shape covers both.

`router = 0` is reported as a NOTE, not a mismatch. It is the legitimate paused state.

### "Parity" means two chains, not two directions

The check operates on **one directed lane**. It never looks at the reverse lane, or asks
whether one exists. What it compares is the source chain's half against the destination
chain's half of that single direction — the halves that `DriftCheck` can only ever see one
at a time.

So a **one-way lane is checked exactly the same way, with one run**, and needs it just as
much: the outbound half lives on the source, the inbound half on the destination, and
nothing else verifies they were built from the same lane file. A bidirectional pair is two
directed lanes, so it takes two runs — and the RPC arguments flip for the reverse one,
since its source is the other chain.

### Running `runConfig` on its own

The first leg needs no RPC, no keys, and no contracts deployed:

```bash
forge script script/governance/LaneParityCheck.s.sol --sig "runConfig(string)" sepolia-to-base_sepolia
```

That makes it the cheapest gate you have — it catches a stale selector, a diverged
`versionTag` or `resolverSalt`, or a missing deployment record before anyone spends gas,
and it can run on every PR. The other two legs need the live chains.

### What must exist on disk

| | |
|---|---|
| `config/lanes/<lane>.json` | one file — the direction being checked |
| `config/chains/<source>.json`, `config/chains/<dest>.json` | both, for the selector, tag and salt comparisons |
| `config/deployments/<source>.json`, `config/deployments/<dest>.json` | both, for the recorded-address comparisons |

`runDest` also reads the **source's** chain config, for its `versionTag` — the inbound map
is keyed by the tag the source stamps, not by whatever the destination declares.

A missing file reverts without the `DRIFT_DETECTED` marker, so the wrapper reports exit
`2` — "couldn't complete the check", not "the lane is wrong". The lane name is matched
against the `name` field inside the JSON, which must equal the filename.

## Deployments report

```bash
make deployments-doc      # regenerate docs/src/deployments.md from config/
make deployments-check    # CI: exit 1 if the page is stale or the resolver diverges
```

Renders the recorded deployments into the [Deployed addresses](deployments.md) page —
no RPC, one row per chain that has both a deployment record and a chain config. Verifiers
are listed as `versionTag` → address. While rendering it asserts the recorded **resolver
address is identical on every chain** and exits `1` if not, so the generator doubles as a
check.

It shows what the records *claim*, not what the chains hold — on-chain truth stays with
drift and parity above. Regenerating the page is a reviewed commit, not a CI side effect:
`--check` only tells you it went stale.

## Role snapshot

```bash
forge script script/governance/SnapshotRoles.s.sol --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
```

Writes every live role holder to `out/governance/` for review, and can be promoted into
`config/roles/<alias>.json` once confirmed. Useful when adopting a deployment whose
intended roles were never written down.

## Both checks are advisory about intent

They compare declared configuration against on-chain state. They cannot tell you the
*declared* values are the right ones. A lane whose config still holds placeholder values
will read as perfectly clean once those placeholders are applied.
