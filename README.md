# CCV Starter Kit — OnChain (Foundry)

The onchain workstream for the Chainlink **CCV (Crosschain Verifier) Starter Kit**.
It deploys and configures existing, already-audited Chainlink CCV contracts and
provides the deploy / config / governance tooling around them. **No new Solidity is
written here** — the contracts come from `@chainlink/contracts-ccip`, pinned exactly.

> Hosted as a standalone Foundry repo under the `smartcontractkit` GitHub org.

## What gets deployed

On **every chain, on both sides of every lane** (first project ≈ 8 lanes):

| Contract | How it's deployed | Address determinism |
|---|---|---|
| `CREATE2Factory` | Fresh deployer EOA, first tx (nonce 0) | Same address everywhere (via nonce-0 CREATE) |
| `VersionedVerifierResolver` | Via the factory, fixed CREATE2 salt | **Same address everywhere** (no constructor args) |
| `CommitteeVerifier` | Plain CREATE, constructor args | May differ per chain — rotates behind the resolver |

Only the **resolver** needs a deterministic address; the verifier rotates behind it.

## Layout

```
config/          config-as-data (per chain / per lane / per role / deployments)
script/
  deploy/        BootstrapFactory (EOA-only), DeployResolver (CREATE2), DeployVerifier
  configure/     one script per privileged call, looped over lanes/chains
  ownership/     per-target 2-step transfers (owners + storageLocationsAdmin)
  fees/          SweepFees + BalanceReport (both contracts, zero-aggregator guard)
  governance/    SnapshotRoles, DriftCheck (+ drift-check.sh with distinct exit codes)
src/lib/         ConfigLib (loader), BaseScript (EOA/Safe switch + Safe-JSON emitter), Types
out/safe/        generated Safe Transaction Builder JSON, one subdir per chain alias
test/            unit + integration (fork) tests
```

See [`config/README.md`](config/README.md) for the full JSON schema.

## Prerequisites

```bash
foundryup -v v1.8.1         # match CI; `exclude_lints` in foundry.toml needs >= 1.8.0
npm install                 # installs @chainlink/contracts-ccip@2.0.0 (pinned) + deps
forge install foundry-rs/forge-std   # or: git submodule; provides lib/forge-std
cp .env.example .env        # then fill in RPC URLs, KMS/keys, explorer keys
```

Compiler settings are pinned in `foundry.toml` (`solc 0.8.26`, `evm_version paris`,
`optimizer_runs 80000`, `via_ir`, `bytecode_hash = "none"`) to match Chainlink's
release profile — required for CREATE2 determinism and source verification.

```bash
forge build                       # production (deterministic) profile
FOUNDRY_PROFILE=dev forge build   # fast iteration (NOT address-compatible)
forge test
```

## Phase 1 — EOA path (deployable & testable fast)

```bash
export OUTPUT_MODE=EOA
# 3) bootstrap the factory (fresh nonce-0 deployer!) and record its address
forge script script/deploy/BootstrapFactory.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
# 4) resolver via CREATE2 (assert address parity vs other chains)
forge script script/deploy/DeployResolver.s.sol --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
# 5) verifier
forge script script/deploy/DeployVerifier.s.sol --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
# 6-12) configure (looped over config/lanes and config/chains)
forge script script/configure/ApplySignatureConfigs.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
# ... remaining configure scripts ...
```

Signing: use Foundry's native KMS (`--aws` / GCP flags) for the deployer/broadcaster
key so no raw key touches disk. (This is the **in-scope** KMS concern; the verifier
node's off-chain ECDSA key is a separate, out-of-scope concern.)

## Phase 2 — Safe path (key-free batches for signers)

Every config / role-transfer script can emit **Safe Transaction Builder JSON** instead
of broadcasting — same script, different mode:

```bash
export OUTPUT_MODE=SAFE
export SAFE_ADDRESS=0x<the executing Safe>
forge script script/ownership/TransferOwnership.s.sol --sig "run(string,string)" sepolia verifier
# -> writes out/safe/sepolia/a-transfer-owner-verifier.json
```

`SAFE_ADDRESS` is required in SAFE mode and recorded in each batch as
`meta.createdFromSafeAddress`, so the Transaction Builder flags a batch imported
into a different Safe. In EOA mode the variable is ignored (with a log).

Multi-step ceremonies are split into **ordered** batch files (`a-` then `b-`, one
directory per chain alias) so a signer can't execute steps out of order and permanently
lock a contract. Handover order is **grant-new-before-revoke-old**; revoke the old
holder only after onchain acceptance is confirmed.

## Handover (per-target two-step ceremonies)

Each role moves via its own `a-`/`b-` pair, one batch per target, and **each party
prepares its own leg** in whichever mode fits its wallet: a Safe generates the batch
with its own `SAFE_ADDRESS`; an EOA runs the same script in EOA mode with
`--broadcast`. The current holder executes the `a-` (propose) leg; the incoming
holder executes the `b-` (accept) leg — or simply calls `acceptOwnership()` from
their own tooling, since the propose leg already made them the pending holder.

1. Owners — `TransferOwnership` / `AcceptOwnership`, target `verifier`, `resolver`
   or `factory`.
2. `storageLocationsAdmin` — `TransferStorageLocationsAdmin` /
   `AcceptStorageLocationsAdmin`; a **separate** admin role from the owner.
3. Transitional `DynamicConfig` roles (allowlistAdmin / feeAggregator) are not
   two-step: re-point them via `SetDynamicConfig` only AFTER acceptance is confirmed
   on-chain.

A mistaken or stale proposal is cancelled by the **current** holder via
`CancelOwnership` / `CancelStorageLocationsAdmin`, which re-propose `address(0)`
so nobody can accept. Cancellation only clears the pending slot — it never moves
the role.

## Operational notes

- **Two distinct fee destinations.** The verifier's `DynamicConfig.feeAggregator`
  and the resolver's `setFeeAggregator` are different — set **both**. A zero
  aggregator makes fee withdrawals revert.
- **Emergency lever asymmetry.** There is **no pause function**. The only emergency
  lever is **outbound**: set `router = 0` for a destination via
  `applyRemoteChainConfigUpdates`. There is **no inbound halt** — don't hunt for one.
- **`versionTag`** is `bytes4`, non-zero, immutable. A new tag ⇒ a new verifier
  deployment + resolver re-wiring. Scheme: 2 bytes operator id + 2 bytes version.
- **`storageLocations`** is the operator's own aggregator endpoint URL — a per-deployment
  input from the off-chain/infra workstream, updatable later by the `storageLocationsAdmin`.

## Deployed addresses (outline step 17)

Record every deployment in `config/deployments/<alias>.json` and summarize here.

| Chain | Factory | Resolver | Verifier | Explorer |
|---|---|---|---|---|
| Sepolia | `0x…` | `0x…` | `0x…` | [link](#) |
| Base Sepolia | `0x…` | `0x…` | `0x…` | [link](#) |

**CREATE2 factory salt (resolver):** `0x…` (must be identical on every chain).

### Source verification

Deploy with the default (release) profile, then:

```bash
forge verify-contract <address> VersionedVerifierResolver --chain <id> --watch
forge verify-contract <address> CommitteeVerifier --chain <id> --constructor-args <abi-encoded> --watch
```

## Testing

- **(a)** unit / integration (fork) tests for the deploy and config scripts — `test/`.
  Fixtures are modelled on Chainlink's own `*Setup.t.sol`.
- **(b)** end-to-end acceptance proof on a real lane. The acceptance fixtures (token,
  token pools, CCV-requiring receiver) are **Chainlink Labs'** deliverable; if late, a
  stopgap CCV-requiring receiver must be authored (open point 12).

## Open items to confirm

- **Lane config direction mapping** vs Chainlink's `configure_committee_verifier_for_lanes.go`
  (which side each call executes on).
- **Committee size / threshold / test lane** (open point 7): default must not be 1-of-1
  and threshold must exceed 2/3 (e.g. 10 → 7).
- **CREATE2 determinism across chains**: needs a fresh nonce-0 deployer on every target
  chain and identical initcode everywhere — the biggest subtle risk at ~8 chains.
