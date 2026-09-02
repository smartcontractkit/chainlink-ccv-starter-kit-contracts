# Introduction

The onchain workstream for the Chainlink **CCV (Cross-Chain Verifier) Starter Kit**.

This repo deploys and configures already-audited Chainlink CCV contracts and provides the
deploy, configuration and governance tooling around them. **No new contracts are built
here** — every contract comes from `@chainlink/contracts-ccip`, pinned to an exact
version. The Solidity in this repo is scripts, libraries and tests; none of it goes
on-chain.

## What a CCV does

A Cross-Chain Verifier attests that a message really was sent on the source chain. When a
message leaves chain A for chain B:

1. On **A**, the OnRamp asks your resolver which verifier handles traffic bound for B, and
   calls it. The verifier stamps its version tag into the message's verifier results.
2. **Off-chain**, a committee of signers observes the message and signs it. That committee
   is a separate workstream — this repo only configures who the signers *are*.
3. On **B**, the OffRamp asks your resolver which verifier handles that version tag, and
   calls it to check the signatures.

In practice that means deploying the two contracts on every chain, then configuring each
side with what it needs to know about the other.

## What gets deployed

On **every chain, on both sides of every lane**:

| Contract | How it's deployed | Address determinism |
|---|---|---|
| `CREATE2Factory` | fresh deployer EOA, first transaction (nonce 0) | same address everywhere |
| `VersionedVerifierResolver` | via the factory, fixed CREATE2 salt | **same address everywhere** (no constructor args) |
| `CommitteeVerifier` | plain `CREATE`, with constructor args | may differ per chain — rotates behind the resolver |

Only the **resolver** needs a deterministic address. Verifiers are free to differ per
chain and to be replaced over time, because callers reach them through the resolver rather
than directly. A chain can run **several verifiers at once** — each has an immutable
`versionTag`, and each lane pins the tag it uses.

That determinism is not automatic. It requires a deployer at nonce 0 on every target
chain and byte-identical initcode everywhere — see [Deploying](deploy.md).

## Repository layout

```
config/          config-as-data: version-tag catalog, chains, lanes, roles, deployments
script/
  deploy/        BootstrapFactory, DeployResolver, DeployVerifier
  configure/     one script per privileged call, for one chain at a time
  config/        sync-ccip-config.sh — fetch Chainlink's chain values from the CCIP API
  ownership/     two-step transfers, per target
  fees/          SweepFees, BalanceReport
  governance/    SnapshotRoles, DriftCheck, LaneParityCheck, deployments-report (+ wrappers)
src/lib/         ConfigLib (loader), BaseScript (EOA/Safe switch), Types
artifacts/       forge build output (foundry.toml sets `out = "artifacts"`, not `out/`)
out/safe/        generated Safe Transaction Builder batches, one directory per chain
out/governance/  role snapshots from SnapshotRoles (gitignored, run-local)
test/            unit and integration tests
```

Foundry's compiled contract artifacts live under `artifacts/`. The `out/` directory is a
hand-rolled tree for Safe batches and governance snapshots — not the default Foundry build
folder.

## How to read this book

If you are onboarding, follow the chapters in order:

| step | chapter | what you get |
|---|---|---|
| 1 | [Getting started](getting-started.md) | install, build, test, the rules every script needs |
| 2 | [Configuration](configuration.md) | how chains, lanes, roles and version tags fit together |
| 3 | [Syncing chain config](config-sync.md) | pull Chainlink's router/RMN values from their API |
| 4 | [Deploying](deploy.md) | factory → resolver → verifier, per chain |
| 5 | [Configuring the contracts](configure.md) | wire verifiers and resolver to each lane |
| 6 | [Full flow example](full-flow.md) | the whole sequence as copy-paste commands — **read after steps 2–5** |
| 7 | [Governance checks](governance.md) | confirm config matches chain state before going live |
| 8 | [Handover](handover.md) | move roles to long-term holders |

Steps 2–5 are the reference; step 6 is the walkthrough that assumes them. When you run
for real, keep the full flow open and link back to the earlier chapters when a step needs
detail.

After that, use [Safe batches](safe-batches.md) when signers should not hold keys,
[Operational notes](operations.md) for runtime behaviour, and
[Troubleshooting](troubleshooting.md) when something fails.

## Two ways to run everything

Every configuration and role-transfer script works in two modes. **Both require an explicit
`OUTPUT_MODE`** — there is no default:

```bash
export OUTPUT_MODE=EOA    # broadcast immediately (also pass --broadcast and a signer)
# or
export OUTPUT_MODE=SAFE
export SAFE_ADDRESS=0x<executing Safe>
```

- **`EOA`** — each staged call is broadcast immediately. Fast, good for testnets. Pair
  with `--broadcast` and a signer flag (`--aws`, etc.).
- **`SAFE`** — calls are buffered and written as Safe Transaction Builder JSON. Nothing
  is broadcast; signers import the file. Requires `SAFE_ADDRESS`.

Misspelling the mode (`Safe`, `safe`, empty, unset) **reverts the script** rather than
guessing. The same script produces both modes. See [Safe batches](safe-batches.md).
