# CCV Starter Kit — On-Chain (Foundry)

Starter Kit for Chainlink Cross-Chain Verifiers (CCVs) on-chain deployment and configuration.

> **Note**
>
> _This repository provides on-chain deployment, configuration, and governance tooling for the Chainlink CCIP Cross-Chain Verifier (Foundry scripts that deploy and configure the audited CCIP CCV contracts). It has not been independently audited by a third-party security firm. It is provided "AS IS" and "AS AVAILABLE", without warranties of any kind, and is not a substitute for your own security review. You are responsible for adapting it to your own infrastructure, following the minimum committee sizing and operational recommendations in the documentation, and for reviewing, testing, configuring, and auditing your deployment before production use. Neither Chainlink Labs, the Chainlink Foundation, nor Chainlink node operators are responsible for any losses or unintended outcomes arising from its use._


The onchain workstream for the Chainlink **CCV (Crosschain Verifier) Starter Kit**.
It deploys and configures existing, already-audited Chainlink CCV contracts and
provides the deploy / config / governance tooling around them. **No new Solidity is
written here** — the contracts come from `@chainlink/contracts-ccip`, pinned exactly.

## Documentation

The onboarding guide is an [mdBook](https://rust-lang.github.io/mdBook/) under [`docs/`](docs/).

```bash
cargo install mdbook   # once
mdbook serve docs --open
```

**Reading order** (same as [`docs/src/SUMMARY.md`](docs/src/SUMMARY.md)):

1. [Introduction](docs/src/intro.md) → [Getting started](docs/src/getting-started.md)
2. [Full flow example](docs/src/full-flow.md) — the end-to-end commands; each step links to the depth chapter
3. Depth when a step needs it: [Configuration](docs/src/configuration.md), [Deploying](docs/src/deploy.md), [Configuring the contracts](docs/src/configure.md)
4. [Governance checks](docs/src/governance.md), [Handover](docs/src/handover.md), [Safe batches](docs/src/safe-batches.md)

JSON schema detail: [`config/README.md`](config/README.md). Stuck on an error: [Troubleshooting](docs/src/troubleshooting.md).

## What gets deployed

On **every chain, on both sides of every lane**:

| Contract | How it's deployed | Address determinism |
|---|---|---|
| `CREATE2Factory` | Fresh deployer EOA, first tx (nonce 0) | Same address everywhere (via nonce-0 CREATE) |
| `VersionedVerifierResolver` | Via the factory, fixed CREATE2 salt | **Same address everywhere** (no constructor args) |
| `CommitteeVerifier` | Plain CREATE, constructor args | May differ per chain — rotates behind the resolver |

Only the **resolver** needs a deterministic address. Verifiers rotate behind it; a chain
can run several at once, each identified by an immutable `bytes4` **versionTag**.

## Layout

```
config/          config-as-data (version-tags catalog, chains, lanes, roles, deployments)
script/
  deploy/        BootstrapFactory, DeployResolver, DeployVerifier
  configure/     one script per privileged call, for one chain at a time
  config/        sync-ccip-config.sh — sync Chainlink's chain values from the CCIP API
  ownership/     per-target 2-step transfers (owners + storageLocationsAdmin)
  fees/          SweepFees + BalanceReport
  governance/    SnapshotRoles, DriftCheck, LaneParityCheck, deployments-report (+ wrappers)
src/lib/         ConfigLib, BaseScript (EOA/Safe switch), Types
artifacts/       forge build output (foundry.toml: out = "artifacts")
out/safe/        generated Safe Transaction Builder JSON, one subdir per chain alias
test/            unit + integration tests
```

## Quick start

```bash
foundryup
npm ci
git submodule update --init --recursive
cp .env.example .env
cp config/version-tags.example.json config/version-tags.json
make build
```

Then follow the [full flow](docs/src/full-flow.md) top to bottom — each step links to the
chapter that explains it in depth.

## Testing

```bash
make test          # hermetic; no RPC
make sync-selftest   # offline config-sync selftest
make drift CHAIN=sepolia RPC_URL=$SEPOLIA_RPC_URL
```

## Deployed addresses

Regenerate from local deployment records (gitignored):

```bash
make deployments-doc
```

The committed page is a placeholder until you deploy — see [`docs/src/deployments.md`](docs/src/deployments.md).
