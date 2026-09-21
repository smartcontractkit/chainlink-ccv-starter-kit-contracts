# Troubleshooting

Common failures keyed by symptom or error string. Exit codes from the governance wrappers
are always **0** clean, **1** finding, **2** could not run.

## Before you run anything

| symptom | cause | fix |
|---|---|---|
| `function not found` from `forge script` | missing `--sig` | every script needs an explicit signature, e.g. `--sig "run(string)" sepolia` |
| config file not found / revert on `readChain` | running from wrong directory or no config written yet | run from repo root; follow [step 1 of the full flow](full-flow.md#1-write-the-config) |
| fresh clone, scripts fail immediately | no operator config yet | seed `config/operator.json`, write operator + lane files from the templates — see [Getting started](getting-started.md#a-fresh-clone-has-no-config) |
| uncataloged tag / unknown versionTag | tag missing from `config/operator.json` | add the tag to the catalog before `DeployVerifier` or lane files |

## Deploy

| error / symptom | meaning | fix |
|---|---|---|
| `BootstrapFactory: deployer nonce != 0` | factory is not this account's first tx on the chain | use a fresh deployer at nonce 0, or accept a non-parity factory address on this chain only |
| `DeployResolver: deployed address != predicted` | initcode differed (wrong profile, unpinned deps, different machine paths with metadata hash) | `npm ci`, default profile (`forge build`), confirm `bytecode_hash = "none"` |
| `DeployVerifier: rmn must be non-zero` | chain config has zero or missing RMN | fix `config/chains/<alias>.json`; re-sync from CCIP API if needed |
| `DeployVerifier: verifier.owner role unset` (or storageLocationsAdmin / feeAggregator) | no `verifiers[]` entry for this tag in the operator file | add the entry **before** deploy — see [Deploying §3](deploy.md#3-deploy-the-verifier) |
| resolver addresses differ across chains | factory or initcode diverged | stop; do not configure on top — redeploy from a known-good build on the diverged chain |
| `deploy-verifier` for a tag already deployed on that chain | record already has the tag | **`DeployVerifier: versionTag … already recorded`** — intended rotation: `ALLOW_TAG_REPLACE=true`; otherwise use a new tag |
| broadcast reported a failed tx, later steps say **`no code at …`** | the record was written during simulation, before the tx failed | check the explorer, then delete the stale block from `config/deployments/<alias>.json` and re-deploy |

## Configure

| error / symptom | meaning | fix |
|---|---|---|
| `BaseScript: OUTPUT_MODE must be exactly EOA or SAFE` | `OUTPUT_MODE` unset, empty, or misspelled | export exactly `EOA` or `SAFE` before configure/ownership/fee scripts |
| `BaseScript: SAFE output needs SAFE_ADDRESS` | SAFE mode without executing Safe | set `SAFE_ADDRESS=0x…` to the Safe that will import the batch |
| `BaseScript: no code at verifier …` | RPC points at wrong network or verifier not deployed | check `--rpc-url` matches the chain alias; confirm tag is in deployment record |
| stray lane configured | extra file in `config/operator/lanes/` | only files in that directory are live inputs — move retired lanes out; see [configure § lane directory](configure.md#the-lane-directory-is-the-input-set) |
| `allowedSenders requires allowlistEnabled=true` / `InvalidAllowListRequest` | senders listed while `allowlistEnabled: false` | enable the allowlist, or empty `allowedSenders` |
| committee has no redundancy | threshold == signer count (N-of-N): one offline signer halts the lane | add signers or lower the threshold, or set `ALLOW_WEAK_COMMITTEE=true` for testnets only |
| committee threshold too low | threshold ≤ 2/3 of the signer set | raise the threshold, or set `ALLOW_WEAK_COMMITTEE=true` for testnets only |

## Governance checks

| symptom | meaning | fix |
|---|---|---|
| `make deployments-check` exit 1 with no records | `deployments.md` on disk does not match `config/` (it still holds another deployment's addresses) | regenerate with `make deployments-doc`; the page reads "No deployments recorded yet" until you deploy |
| drift exit 1 | on-chain state ≠ config | read the script output for `DRIFT_DETECTED` lines; fix config or re-run configure |
| drift exit 2 | RPC down, missing deployment record, or revert without drift marker | fix infrastructure first — not the same as drift |
| parity fails on `versionTag` | lane tag ≠ recorded verifier on one chain | deploy verifier with that tag on both chains, or fix the lane file |
| signer sets never checked on a chain | chain is only ever a lane *source* | signer config lives on the destination — run drift on the dest chain too |

## Signing and RPC

| symptom | fix |
|---|---|
| `--rpc-url sepolia` fails | `foundry.toml` rpc_endpoints are commented out by default — pass the full URL (`$SEPOLIA_RPC_URL`) |
| role check evaluated wrong account | keep `--aws` (or your signer flag) even when simulating without `--broadcast` |
| fee sweep reverts `no code at verifier …` | fee scripts read balances at build time and need `--rpc-url` even in SAFE mode — see [Safe batches](safe-batches.md#when-an-rpc-is-required) |

## Things no check can catch

- **Wrong `rmn` at deploy** — immutable, no getter; only prevention is careful review before `deploy-verifier`.
- **Placeholder config applied cleanly** — drift and parity compare config to chain, not intent to production readiness.
- **Retired lane still routable on-chain** — deleting a lane file stops configure scripts from mentioning it, but nothing automatically clears the outbound mapping; see [Operational notes](operations.md#rotating-a-verifier).

For deploy-time revert messages in full, see the table in [Deploying §3](deploy.md#3-deploy-the-verifier).
