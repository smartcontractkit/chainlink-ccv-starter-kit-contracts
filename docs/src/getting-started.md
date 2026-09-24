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
make seed-operator-config             # config/operator.json (resolver salt + tag catalog) from the example
```

Use `npm ci`, not `npm install` — it installs exactly what the lockfile pins and fails
loudly if `package.json` and `package-lock.json` have drifted.

## Build

```bash
make build    # forge build — default profile, pinned for deterministic addresses
```

Always deploy from this profile. Compiler settings live in `foundry.toml`; changing them
breaks CREATE2 address parity across machines — see [Deploying](deploy.md#address-determinism).

## A fresh clone has no config

A fresh clone has templates and examples only; nothing runs until you write your own config:

```bash
# list chains + selectors from the CCIP API — requires: nothing
make discover

# create config/chains/<alias>.json with the Chainlink fields — requires: CHAIN, SELECTOR
make add-chain CHAIN=sepolia SELECTOR=16015286601757825753

# then write config/operator/chains/<alias>.json + lanes from the templates,
# and add your versionTag to config/operator.json (deploy refuses an uncataloged tag)
```

[Step 1 of the full flow](full-flow.md#1-write-the-config) walks through all of it;
[Configuration](configuration.md) explains how the files fit together.

## Running the scripts

Every script runs through a `make` target — run bare `make` (or `make help`) to list
every target with a one-line description. A target checks its variables up front and
exits naming any missing one:

```bash
# requires: CHAIN, TAG, RPC_URL
make deploy-verifier     CHAIN=sepolia TAG=0x00010001 RPC_URL=$SEPOLIA_RPC_URL

# requires: CHAIN, TAG, RPC_URL, OUTPUT_MODE (+ SAFE_ADDRESS in SAFE mode)
make apply-remote-config CHAIN=sepolia TAG=0x00010001 RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
```

What the variables mean:

| variable | needed by | value |
|---|---|---|
| `CHAIN` | every on-chain target | chain alias — `config/chains/<alias>.json` must exist |
| `RPC_URL` | every on-chain target | that chain's endpoint, usually from `.env` (e.g. `$SEPOLIA_RPC_URL`) |
| `TAG` | per-verifier targets | `bytes4` versionTag from `config/operator.json` — selects which recorded verifier when a chain runs several |
| `OUTPUT_MODE` | configure / ownership / fee | exactly `EOA` or `SAFE` (case-sensitive) — **no default**, anything else exits |
| `SAFE_ADDRESS` | `OUTPUT_MODE=SAFE` only | the Safe that will import and execute the batch |
| `TARGET` | owner transfer targets | `verifier:<tag>` \| `resolver` \| `factory` |
| `SIGNER` | EOA broadcasts | signer flags, default `--aws` — see [Signing](#signing) |

In SAFE mode nothing is broadcast — the batch is written under `out/safe/`; see
[Safe batches](safe-batches.md). The deploy targets (`bootstrap-factory`,
`deploy-resolver`, `deploy-verifier`) are EOA-only and always broadcast — a run that does
not broadcast writes no deployment record.

**Run `make` from the repository root.** The scripts resolve `config/…` paths relative to
the working directory, and `foundry.toml`'s `fs_permissions` are rooted there too.

## Signing

EOA broadcasts sign with whatever the `SIGNER` variable holds — default `--aws`,
Foundry's native KMS support, so no raw private key touches disk:

```bash
# requires: AWS credentials in the environment (the default SIGNER=--aws)
make deploy-verifier CHAIN=sepolia TAG=0x00010001 RPC_URL=$SEPOLIA_RPC_URL

# an encrypted local keystore, for local and testnet work
make deploy-verifier CHAIN=sepolia TAG=0x00010001 RPC_URL=$SEPOLIA_RPC_URL \
  SIGNER="--account my-deployer"

# or a raw key
make deploy-verifier CHAIN=sepolia TAG=0x00010001 RPC_URL=$SEPOLIA_RPC_URL \
  SIGNER="--private-key $PRIVATE_KEY"
```

`SIGNER` is passed through to `forge script` untouched, so any Foundry wallet flag
works: `--aws`, `--gcp`, `--account <name>` for a keystore under `~/.foundry/keystores`,
`--keystore <path>` for one elsewhere, `--private-key`, or a hardware wallet. Import a
keystore once with `cast wallet import <name> --interactive`; forge then prompts for the
password, or reads it from `--password-file`.

Prefer `--account` over `--private-key` for local work. A raw key on the command line
lands in shell history and is visible in the process list.

This covers the deployer and broadcaster key only. The verifier committee's off-chain
signing keys are a separate concern, handled outside this repo.

## Next step

Once the repo builds, go to the [full flow example](full-flow.md) and
follow it top to bottom. It links into [Configuration](configuration.md),
[Deploying](deploy.md) and [Configuring the contracts](configure.md) wherever a step
needs depth.
