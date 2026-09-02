# Getting started

## Prerequisites

Needed for everything here:

- [**Foundry**](https://www.getfoundry.sh/introduction/installation) — build, test, and
  every deploy/configure script runs through `forge`
- **Node.js** — `npm ci` installs `@chainlink/contracts-ccip`, which the contracts import
- **`git`** — `forge-std` is a submodule
- **`jq`** and **`curl`** — the shell wrappers parse config with `jq`, and the config-sync
  scripts fetch over `curl`. Both are checked at startup; a missing one exits
  `2 MISSING_TOOL`.
- **`bash`** — the wrappers use process substitution, so `sh` will not run them

Needed only for specific `make` targets:

| tool | target | install |
|---|---|---|
| `shellcheck` | `make lint-sh` | `brew install shellcheck` |
| `typos-cli` | `make lint-typos` | `cargo install typos-cli` |
| `mdbook` | `mdbook serve docs --open` | `cargo install mdbook` |

## Install

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup   # Foundry — see their guide for alternatives

npm ci                                # clean install, exactly what package-lock.json pins
git submodule update --init --recursive   # forge-std, pinned by foundry.lock
cp .env.example .env                  # then fill in RPC URLs and signing config
cp config/version-tags.example.json config/version-tags.json   # tag catalog for your deployment
```

Use `npm ci`, not `npm install` — it installs exactly what the lockfile pins and fails
loudly if `package.json` and `package-lock.json` have drifted.

## A fresh clone has no config

`config/` ships only `_template.json` and `*.example.json` files. Real per-chain, per-lane
and per-role config is gitignored: those files carry live addresses, and every deployment's
set differs. So a clone has nothing for the scripts to read, and each one fails on a
missing file until you write your own —
[step 1 of the full flow](full-flow.md#1-write-the-config) is not an optional step.

You also need `config/version-tags.json` — the repo-wide catalog of every `versionTag`
your deployment uses. `DeployVerifier` refuses an uncataloged tag, and lane files may only
pin catalogued tags. Copy the example file and add an entry before your first deploy.

## Running the scripts

Three rules hold for every invocation in this book.

**Always pass `--sig`.** No script has a zero-argument `run()` — every one takes at least a
chain alias — and `forge script` needs the signature to pick an entry point. Omit it and
Foundry fails with a bare "function not found" that names nothing.

```bash
export TAG=0x00010001   # your choice — catalog it, use the same tag on both sides of every lane

forge script script/deploy/DeployVerifier.s.sol --sig "run(string,bytes4)" sepolia $TAG \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
```

**Set `OUTPUT_MODE` explicitly on configure / ownership / fee scripts.** There is no
default — exactly `EOA` or `SAFE` (case-sensitive). Anything else reverts. SAFE mode also
needs `SAFE_ADDRESS`.

| script kind | mode | `--broadcast`? |
|---|---|---|
| deploy (`BootstrapFactory`, `DeployResolver`, `DeployVerifier`) | EOA only | **always** |
| configure / ownership / fee | `OUTPUT_MODE=EOA` | **yes**, plus a signer |
| configure / ownership / fee | `OUTPUT_MODE=SAFE` | **no** |

Deploy scripts write `config/deployments/` even without `--broadcast` — do not dry-run them.

```bash
# EOA configure
export OUTPUT_MODE=EOA
forge script script/configure/SetFeeAggregator.s.sol --sig "run(string)" sepolia \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --aws

# Safe configure — no --broadcast
export OUTPUT_MODE=SAFE
export SAFE_ADDRESS=0x<executing Safe>
forge script script/configure/SetFeeAggregator.s.sol --sig "run(string)" sepolia \
  --rpc-url $SEPOLIA_RPC_URL
```

Many configure and ownership scripts take a **`bytes4` versionTag** as well as the chain
alias — it selects which recorded verifier to act on when a chain runs more than one.
You pick the tag; it must be listed in `config/version-tags.json` and the same on both
chains of each lane. The [full flow](full-flow.md) uses `0x00010001` as its example only.

**Run from the repository root.** `ConfigLib` builds paths like `config/chains/<alias>.json`
relative to the working directory, and `foundry.toml`'s `fs_permissions` are rooted there
too, so a script started from a subdirectory cannot read its config. The shell wrappers
differ here: `deployments-report.sh`, `sync-ccip-config.sh` and `selftest.sh` `cd` to the
root themselves; `drift-check.sh` and `lane-parity-check.sh` do not.

## Build

```bash
make build    # forge build — default profile, pinned for deterministic addresses
make test     # no RPC needed
```

Always deploy from this profile. Compiler settings live in `foundry.toml`; changing them
breaks CREATE2 address parity across machines — see [Deploying](deploy.md#address-determinism).

## Signing

For the EOA path, use Foundry's native KMS support (`--aws`, or the GCP equivalent) so no
raw private key touches disk:

```bash
forge script ... --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
```

This covers the deployer and broadcaster key only. The verifier committee's off-chain
signing keys are a separate concern, handled outside this repo.

## Next step

Once the repo builds and tests pass, read [Configuration](configuration.md) and
[Syncing chain config](config-sync.md), then [Deploying](deploy.md) and
[Configuring the contracts](configure.md). When those make sense, run through the
[full flow example](full-flow.md).
