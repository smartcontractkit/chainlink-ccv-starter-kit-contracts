# Configuration

Everything is config-as-data. The scripts read these JSON files at runtime, so the same
script serves every chain and every lane with nothing hardcoded — you select the target by passing a chain alias.

```
config/
  version-tags.json           repo-wide catalog of every versionTag in use (one spelling everywhere)
  chains/<alias>.json         per chain: router, RMN, storage locations, resolver salt, finalityConfig
  lanes/<source>-to-<dest>.json   per DIRECTED lane: versionTag, signers, fees, allowlist
  roles/<alias>.json          per chain: who should hold each privileged role (per verifier tag)
  deployments/<alias>.json    per chain: recorded addresses; verifiers[] maps tag → address
```

Files named `_template.json` document the full schema. Files ending `.example.json` are
illustrative. Real per-deployment files are named after the chain alias (`sepolia.json`)
or the lane (`sepolia-to-base_sepolia.json`).

See [Config file schema](config-schema.md) for the full field-by-field reference.

## Where the Chainlink fields come from

The Chainlink-provided fields in a chain file — `router`, `rmn`, `chainId`, `feeTokens`,
`explorerAddressPath` — are fetched from the public CCIP API, never typed by hand.
Everything else (`resolverSalt`, `storageLocations`, `finalityConfig`) is operator-owned;
the sync tooling never touches those.

Onboarding a new chain:

```bash
# 1. find the chain's selector — requires: nothing
make discover

# 2. create config/chains/<alias>.json with the Chainlink fields filled in
#    requires: CHAIN, SELECTOR
make add-chain CHAIN=sepolia SELECTOR=16015286601757825753

# 3. hand-fill the operator fields it lists as "still to fill in", then deploy
```

`add-chain` never overwrites an existing file — re-running it prints `OK` if the file
agrees with the API, or a field-by-field `WARN` diff if it does not, and writes nothing.

Staying in sync:

```bash
make sync-check                # read-only, all chains; run on a schedule
make sync-chain CHAIN=sepolia  # accept upstream values, one chain — requires: CHAIN
```

`sync-check` never writes and uses the same exit codes as the governance checks
(**0** clean, **1** drift, **2** couldn't run), so it slots into the same CI shape.

`sync-chain` accepts upstream values one chain at a time, because `rmn` is **immutable
inside a deployed verifier and has no getter** — the config file is the only record of
what was deployed. Treat a post-deploy `rmn` drift as something to investigate, one
chain at a time.

`explorerAddressPath` is nullable upstream. When the API serves no explorer for a chain
the field is skipped entirely — never compared, never written — so a value you set by
hand survives every sync.

Field semantics, the `--env mainnet` flag, and debugging the raw API output are in
[Config sync commands](config-sync-reference.md).

## Lanes are directed

A lane file describes traffic in **one direction only**: `<source>-to-<dest>.json` covers
source → destination. Traffic the other way is its own lane — a second file with the
names flipped.

This is not bookkeeping — each field belongs to one side, so reversing the direction
changes what every value means:

| field | belongs to |
|---|---|
| `versionTag` | both — must match in the two directions' files |
| router used | the **source's** local router |
| `signatureConfig` | written to the **destination's** verifier |
| `allowlist` | senders on the **source** chain |

The router is the **local** router of whichever chain is the *source* — not the remote
chain's router. You normally don't write it at all: leave `remoteChainConfig.router` out
of the lane file and it is inherited from the source chain's `chains/<alias>.json`, which
is kept correct by the [sync tooling](#where-the-chainlink-fields-come-from). Set it explicitly only to
`0x0`, to pause the lane.

The two committees may also differ legitimately. Nothing requires the signer set that
verifies A → B to equal the one that verifies B → A.

## Values that must match across chains

Two fields must agree on both chains of a lane:

- **`versionTag`** — mandatory in each lane file. Both endpoints must deploy a verifier
  with that tag and record it in `deployments/<alias>.json`. The destination verifier
  rejects any message whose tag is not its own; the tag is immutable, so a mismatch means
  redeploying the verifier.
- **`resolverSalt`** — in each chain file. Determines the resolver's CREATE2 address.
  Different salts mean different addresses.

`LaneParityCheck` asserts both, plus that the recorded resolver addresses actually agree —
matching salts are necessary but not sufficient, since the factory address and initcode
must match too. See [Governance checks](governance.md).

The tag must also appear in `config/version-tags.json` before deploy, and each chain's
`config/roles/<alias>.json` must declare a `verifiers[]` entry for it — `DeployVerifier`
reads that entry and refuses a tag with no roles row.

## What `versionTag` is, and is not

A `bytes4` fixed at construction, chosen at deploy time and passed to `DeployVerifier` as
an argument. It is the only thing that crosses the chain boundary — the destination
resolver looks up an incoming message's tag to find the local verifier that should check
it.

Each **lane** pins the tag it uses via its mandatory `versionTag` field. A chain can run
several verifiers at once (each with a different tag); lanes migrate individually by
flipping their tag and re-running configure. The repo-wide spelling lives in
`config/version-tags.json`.

The suggested scheme is two bytes of operator id and two of version, so `0xAABBCCDD` reads
as operator `AABB` at version `CCDD`. The catalog loader enforces non-zero halves; the
contracts treat the tag as an opaque `bytes4`.

What it is **not** is your defence against signature replay across verifiers. Chainlink's
own note on `i_versionTag` is explicit: it can serve as a domain separator, but should
never be the primary defence — that job belongs to **non-overlapping signer sets**, so a
signature produced for one verifier is not valid for another regardless of tags. Treat the
tag as protection against *accidental* misuse, not against an attacker.

The practical consequence for `config/lanes/*.json`: if two verifiers share committee
members, giving them different `versionTag`s does not isolate them. Separate the signer
sets instead.

## What `finalityConfig` allows

A `bytes4` FinalityCodec value, set per verifier by `SetAllowedFinalityConfig`. It caps
what a **sender** may request; it is not a setting the verifier applies to itself.

One `bytes4` split in half — 16 flag bits above, a 16-bit block depth below:

```
 bits 31..16  flags                        bits 15..0  block depth (max 65535)
   bit 16      WAIT_FOR_SAFE_FLAG
   bits 17..31 reserved, accepted but unassigned
```

Three modes come out of that:

| value | meaning |
|---|---|
| `0x00000000` | wait for full finality |
| `0x00010000` | wait for the `safe` head — flag only, no depth |
| `0x00000001`–`0x0000FFFF` | wait for N blocks |

An encoded depth of zero *is* finality, not "no wait". A **request** must be exactly one
mode; the **cap** may combine several — `0x00010005` permits both `safe` and depth
requests. Requested full finality is always allowed, whatever the cap says.

The cap's depth is a **floor**, so a bigger number permits less:

| `finalityConfig` | a sender may request |
|---|---|
| `0x00000000` | full finality only — **strictest, and the default** |
| `0x00000005` | full finality, or a depth of 5 or more |
| `0x00000001` | full finality, or **any** depth at all — the most permissive setting |

A low floor is a real trade: a depth-1 attestation can be reorged out on the source after
the destination has already acted on the message. `0x00000000` is the safe default.

The cap is enforced on the **source**, at quote time: a disallowed finality fails in the
verifier's `getFee`; the inbound path never looks at finality. And it applies per
**verifier**, not per lane — running one destination on the fast path and another on full
finality takes a second verifier with its own `versionTag`.

## The `router = 0` lever

Setting `remoteChainConfig.router` to the zero address **in the lane file** is the
**only** emergency lever, and it pauses **outbound** traffic for that one destination.
(It overrides the router normally inherited from the chain config.)

There is no pause function and no inbound halt. See
[Operational notes](operations.md#there-is-no-pause-function).

Note that `gasForVerification` must stay non-zero even when pausing — `BaseVerifier`
reverts `DestGasCannotBeZero` regardless of the router value.
