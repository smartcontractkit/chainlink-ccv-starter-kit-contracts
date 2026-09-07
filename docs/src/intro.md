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

The directories you touch as an operator:

```
config/          config-as-data: version-tag catalog, chains, lanes, roles, deployments
script/          deploy, configure, ownership, fees, governance, config-sync — one script per action
out/safe/        generated Safe Transaction Builder batches, one directory per chain
out/governance/  role snapshots (gitignored, run-local)
artifacts/       forge build output (foundry.toml repurposes `out/` for the two trees above)
```

## How to read this book

The path is two chapters: [Getting started](getting-started.md) (install, build, how the
`make` targets work), then the [full flow example](full-flow.md) — the whole sequence as
copy-paste commands, from writing the config to accepting handover. Follow the full flow
top to bottom; each step links to the chapter that explains it in depth when you want the
why:

| chapter | depth on |
|---|---|
| [Configuration](configuration.md) | how chains, lanes, roles and version tags fit together |
| [Deploying](deploy.md) | factory → resolver → verifier, per chain |
| [Configuring the contracts](configure.md) | wire verifiers and resolver to each lane |
| [Governance checks](governance.md) | confirm config matches chain state before going live |
| [Handover](handover.md) | move roles to long-term holders |

After that, use [Safe batches](safe-batches.md) when signers should not hold keys,
[Operational notes](operations.md) for runtime behaviour, and
[Troubleshooting](troubleshooting.md) when something fails.

Every configuration and role-transfer script runs in one of two explicit modes:
`OUTPUT_MODE=EOA` broadcasts now with a signer, `OUTPUT_MODE=SAFE` writes a Safe
Transaction Builder batch instead. There is no default — see
[Safe batches](safe-batches.md).
