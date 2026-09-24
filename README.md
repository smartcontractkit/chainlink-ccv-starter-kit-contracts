# CCV Starter Kit — On-Chain (Foundry)

Starter Kit for Chainlink Cross-Chain Verifiers (CCVs) on-chain deployment and configuration.

> [!IMPORTANT]
> The CCV Starter Kit spans two repositories. This one deploys and configures the on-chain contracts.
> [chainlink-ccv-starter-kit](https://github.com/smartcontractkit/chainlink-ccv-starter-kit) runs the
> verifier and aggregator services. Operating a CCV requires both.

> [!NOTE]
> **Building a Cross-Chain Verifier?** If you have questions about this kit, about operating a CCV, or about
> getting your verifier onboarded into the CCIP indexer, contact us at
> [clusersupport@smartcontract.com](mailto:clusersupport@smartcontract.com).

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
config/          config-as-data (synced chain reference, operator intent, lanes, deployments)
script/
  deploy/        BootstrapFactory, DeployResolver, DeployVerifier
  configure/     one script per privileged call, for one chain at a time
  config/        sync-ccip-config.sh — sync Chainlink's chain values from the CCIP API
  ownership/     per-target 2-step transfers (owners + storageLocationsAdmin)
  fees/          SweepFees + BalanceReport
  governance/    ValidateConfig, SnapshotOperator, DriftCheck, LaneParityCheck, deployments-report (+ wrappers)
src/lib/         ConfigLib, BaseScript (EOA/Safe switch), Types
artifacts/       forge build output (foundry.toml: out = "artifacts")
out/safe/        generated Safe Transaction Builder JSON, one subdir per chain alias
test/            unit + integration tests
```

## Quick start

Fork this repository and clone your fork. Your config and deployment records live in
[`config/`](config/README.md) and belong in your own git history.

```bash
make install                # forge 1.8.1 (the version the Makefile and CI pin) + npm ci + git submodules
cp .env.example .env
make seed-operator-config   # config/operator.json from the example, if absent
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

Regenerate from your local deployment records:

```bash
make deployments-doc
```

The page is a placeholder until you deploy and run `make deployments-doc` — see [`docs/src/deployments.md`](docs/src/deployments.md).
