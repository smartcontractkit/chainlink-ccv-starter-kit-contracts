# Deploying

Three contracts per chain, deployed in a fixed order. All three are EOA-only by design —
they depend on a fresh deployer and are not routed through a Safe.

```bash
export OUTPUT_MODE=EOA
export TAG=0x00010001    # your tag — must be in config/version-tags.json
```

Each step has a make shortcut. This is the authoritative mapping — the make target runs
exactly the forge command beside it, with `OUTPUT_MODE=EOA` and `$(SIGNER)` prepended:

| make target | equivalent forge command |
|---|---|
| `make bootstrap-factory CHAIN=<alias> RPC_URL=<url>` | `forge script script/deploy/BootstrapFactory.s.sol --sig "run(string)" <alias> --rpc-url <url> --broadcast $SIGNER` |
| `make deploy-resolver CHAIN=<alias> RPC_URL=<url>` | `forge script script/deploy/DeployResolver.s.sol --sig "run(string)" <alias> --rpc-url <url> --broadcast $SIGNER` |
| `make deploy-verifier CHAIN=<alias> TAG=<tag> RPC_URL=<url>` | `forge script script/deploy/DeployVerifier.s.sol --sig "run(string,bytes4)" <alias> <tag> --rpc-url <url> --broadcast $SIGNER` |

`CHAIN` has no default — pass it explicitly. `RPC_URL` must be that chain's endpoint.
`TAG` is required for `deploy-verifier` (any catalogued `bytes4` you chose). `SIGNER` defaults to
`--aws`; override with e.g. `SIGNER="--private-key $PRIVATE_KEY"`.

Foundry simulates before it broadcasts when you pass `--broadcast`. Keep the signer flag —
`msg.sender` is what these scripts check against, and without one Foundry substitutes a
default sender, so the nonce and role checks evaluate against the wrong address.

Deploy scripts write `config/deployments/` even without `--broadcast` — use the `make`
targets and do not dry-run them.

**Before `deploy-verifier`**, ensure:

1. The tag is listed in `config/version-tags.json`.
2. `config/roles/<alias>.json` has a `verifiers[]` entry for that tag (owner,
   `storageLocationsAdmin`, `feeAggregator`, `allowlistAdmin`).
3. `rmn` in the chain config is non-zero and correct — it is immutable with no getter.

**Deploying also hands over roles.** All three scripts read
`config/roles/<alias>.json` and *propose* the roles declared there to their intended
holders. Every one of these roles is two-step, so proposing changes nothing on its own:
the deployer keeps the role until the incoming holder accepts, via
[handover](handover.md). A role whose configured holder is the deployer is left alone.

## 1. Bootstrap the factory

```bash
forge script script/deploy/BootstrapFactory.s.sol \
  --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
```

This **must** be the deployer's first ever transaction on that chain. A `CREATE` address
is `keccak256(rlp([deployer, nonce]))`, so a nonce-0 deployer lands the factory at the
same address on every chain. The script hard-requires it:

```solidity
require(vm.getNonce(deployer) == 0, "BootstrapFactory: deployer nonce != 0 (address parity broken)");
```

The deployer is placed in the factory's allowlist at construction so it can drive the
CREATE2 deploy in the next step. Ownership then goes to the configured
`factory.owner` from `config/roles/<alias>.json` — as a *proposal*, since `CREATE2Factory`
is `Ownable2Step`. Leave it unset (or equal to the deployer) to keep the deployer as owner.

The factory address is recorded into `config/deployments/<alias>.json`.

## 2. Deploy the resolver

```bash
forge script script/deploy/DeployResolver.s.sol \
  --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
```

Deployed through the factory with the fixed `resolverSalt` from the chain config. The
resolver has no constructor arguments, so its initcode is just its creation bytecode —
nothing per-chain can perturb the address.

The script precomputes the address, deploys, and asserts they match:

```solidity
require(resolver == predicted, "DeployResolver: deployed address != predicted (determinism broken)");
```

Ownership is proposed to `resolver.owner`. If that is the deployer, the script accepts
in-place so the resolver is immediately usable.

**Confirm the resolver address matches the other chains before continuing.** Divergence
here is silent and only surfaces later as fee-quoting reverts.

## 3. Deploy the verifier

```bash
forge script script/deploy/DeployVerifier.s.sol \
  --sig "run(string,bytes4)" sepolia 0x00010001 --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
```

The `bytes4` tag is an explicit deploy argument — each run appends a new entry to
`deployments/<alias>.json`'s `verifiers[]` array. A duplicate tag reverts unless
`ALLOW_TAG_REPLACE=true` (for redoing a failed deploy before anything references it).

Five values must be set before this runs — two from the chain config, three from the roles
file for this tag. The script checks all five up front:

| Requirement | Source file | Revert message |
|---|---|---|
| `rmn` non-zero | `config/chains/<alias>.json` | `DeployVerifier: rmn must be non-zero` |
| tag non-zero and catalogued | deploy argument + `config/version-tags.json` | `DeployVerifier: versionTag must be non-zero` / catalog error |
| `verifier.owner` set | `config/roles/<alias>.json` → `verifiers[]` for tag | `DeployVerifier: verifier.owner role unset` |
| `verifier.storageLocationsAdmin` set | same | `DeployVerifier: verifier.storageLocationsAdmin role unset` |
| `verifier.feeAggregator` set | same | `DeployVerifier: verifier.feeAggregator role unset` |

`allowlistAdmin` is read from the same roles entry but is *not* checked — a zero value
deploys fine.

Plain `CREATE` with constructor arguments from config: dynamic config (from roles),
storage locations and RMN (from chain config), and the deploy-time `versionTag`. Its
address will differ per chain — that is fine, because callers reach it through the resolver.

This script hands over **two** roles, both as proposals:

- **`verifier.owner`** — gates every owner-only configure script. Until it is accepted,
  the deployer is still the owner and can keep configuring.
- **`verifier.storageLocationsAdmin`** — the constructor seeds this to the deployer, and
  the script proposes it onward.

`storageLocationsAdmin` is **not** carried by ownership, in either direction. It is a
separate two-step role with its own transfer pair, and the owner cannot move it:
`transferStorageLocationsAdmin` reverts `OnlyCallableByStorageLocationsAdmin` for anyone
who is not the current admin. There is no owner override, so an admin key lost before the
handover completes leaves `updateStorageLocations` permanently uncallable and needs a
redeployed verifier.

Two constructor arguments are **immutable**:

- **`rmn`** — stored as `IRMN internal immutable i_rmn` with no getter. It cannot be read
  back, so `DriftCheck` can never verify it, and the only way to change it is to redeploy
  the verifier. Worth double-checking against the chain config before this step.
- **`versionTag`** — a new tag means a new verifier deployment plus resolver re-wiring.

## Address determinism

Two preconditions:

1. **Nonce 0 on every target chain.** Enforced by `BootstrapFactory`, so this one fails
   loudly.
2. **Identical initcode everywhere.** Not enforced by anything. It requires the same
   pinned dependencies (`npm ci`) and the default compiler profile on every machine that
   deploys.

The second fails silently — the deploy succeeds, just at a different address. Always
deploy from a fresh `npm ci` install with the default profile, and confirm the resolver
address matches the other chains before configuring anything on top of it.

## Multiple verifiers

To run an upgrade alongside the old verifier:

1. Add the new tag to `config/version-tags.json`.
2. Add a `verifiers[]` roles entry for it.
3. `make deploy-verifier CHAIN=… TAG=<new> RPC_URL=…` on every chain.
4. Migrate lanes one at a time — flip `versionTag` in the lane file, re-run configure.
5. Retire the old verifier once in-flight messages drain — see
   [Rotating a verifier](operations.md#rotating-a-verifier).
