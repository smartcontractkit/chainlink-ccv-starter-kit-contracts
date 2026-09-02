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

The Chainlink-provided fields in a chain file (`router`, `rmn`, `chainId`, `feeTokens`)
are fetched from the CCIP API, not typed by hand — see
[Syncing chain config](config-sync.md).

Files named `_template.json` document the full schema. Files ending `.example.json` are
illustrative. Real per-deployment files are named after the chain alias (`sepolia.json`)
or the lane (`sepolia-to-base_sepolia.json`).

See [Config file schema](config-schema.md) for the full field-by-field reference.

## Lanes are directed

A lane file describes traffic in **one direction only**. `sepolia-to-base_sepolia.json`
covers Sepolia → Base Sepolia. Traffic the other way needs a second file,
`base_sepolia-to-sepolia.json`.

This is not bookkeeping — the two directions carry genuinely different values:

| field | `sepolia-to-base_sepolia` | `base_sepolia-to-sepolia` |
|---|---|---|
| `versionTag` | must match on both lane files | same |
| router used | **Sepolia's** router | **Base Sepolia's** router — a different address |
| `signatureConfig` | written to Base Sepolia's verifier | written to **Sepolia's** verifier |
| `allowlist` | senders on Sepolia | senders on Base Sepolia |

The router is the **local** router of whichever chain is the *source* — not the remote
chain's router. You normally don't write it at all: leave `remoteChainConfig.router` out
of the lane file and it is inherited from the source chain's `chains/<alias>.json`, which
is kept correct by the [config sync tooling](config-sync.md). Set it explicitly only to
`0x0`, to pause the lane.

The two committees may also differ legitimately. Nothing requires the signer set that
verifies A → B to equal the one that verifies B → A.

## Which side each setting lands on

Each setting lands on exactly one side of a lane, keyed by the other side's selector.
A setting written to the wrong side still applies on-chain, so the lane reads as
configured and fails on first use.

| setting | lives on | keyed by | what it controls |
|---|---|---|---|
| `remoteChainConfig` | **source** chain | **dest** selector | what sending to that destination costs, and the gas and payload size reserved for verifying it on arrival |
| `allowlist` | **source** chain | **dest** selector | which senders *on the source* may send to that destination |
| `signatureConfig` | **dest** chain | **source** selector | which committee verifies messages arriving from that source |
| resolver outbound implementation | **source** chain | **dest** selector | which local verifier handles traffic to that destination |
| resolver inbound implementation | **dest** chain | the lane's **`versionTag`** | which local verifier checks messages carrying that tag |

The fee is quoted and charged **on the source**, in US dollar cents, when a message is
sent to that destination — it is a per-destination price, not something held on the other
chain. `gasForVerification` and `payloadSizeBytes` likewise describe work that happens on
the destination but are stored on the source, which needs them to quote and size the
message.

The rule underneath: a contract can only call addresses on its own chain, so every
verifier address stored in a resolver is local to that resolver's chain. The only thing
that crosses the chain boundary is the 4-byte `versionTag`, carried inside the message's
verifier results.

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

"Permissive" means how weak a guarantee a sender may opt into: a floor of one block lets
the committee attest one block after the send, so the source transaction can still be
reorged out while the destination has already acted on it. `0x00000000` is the safe
default — it demands the strongest guarantee that exists, and no cap can refuse it.

The cap is enforced on the **source**, at quote time: a disallowed finality fails in the
verifier's `getFee`; the inbound path never looks at finality. And it applies per
**verifier**, not per lane — running one destination on the fast path and another on full
finality takes a second verifier with its own `versionTag`.

## The `router = 0` lever

Setting `remoteChainConfig.router` to the zero address **in the lane file** is the
**only** emergency lever, and it pauses **outbound** traffic for that one destination.
(It overrides the router normally inherited from the chain config.) It is a legitimate
state, not drift: `LaneParityCheck` reports it as a NOTE rather than a mismatch.

There is no pause function and no inbound halt. See
[Operational notes](operations.md#there-is-no-pause-function).

Note that `gasForVerification` must stay non-zero even when pausing — `BaseVerifier`
reverts `DestGasCannotBeZero` regardless of the router value.
