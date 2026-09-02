# Handover

Roles move in two steps: the current holder proposes, the incoming holder accepts. Each
role has its own pair of scripts, and **each party prepares its own leg**.

**After a fresh deploy, the propose leg is already done.** The deploy scripts propose every
role in `config/roles/<alias>.json` to its configured holder, so only the accept legs below
are outstanding — running `TransferOwnership` again would just re-propose what is already
pending. The transfer scripts are for rotations later, or for a role whose configured
holder was the deployer.

## Owners

```bash
TAG=0x00010001   # example — substitute your catalogued tag

# current holder proposes (verifier target includes the tag)
export OUTPUT_MODE=SAFE
export SAFE_ADDRESS=0x<current owner Safe>

forge script script/ownership/TransferOwnership.s.sol \
  --sig "run(string,string)" sepolia verifier:$TAG --rpc-url $SEPOLIA_RPC_URL
# -> out/safe/sepolia/transfer-owner-verifier-0x00010001.json

# incoming holder runs this THEMSELVES
export SAFE_ADDRESS=0x<incoming holder Safe>

forge script script/ownership/AcceptOwnership.s.sol \
  --sig "run(string,string)" sepolia verifier:$TAG --rpc-url $SEPOLIA_RPC_URL
# -> out/safe/sepolia/accept-owner-verifier-0x00010001.json
```

Targets: `verifier:<versionTag>`, `resolver`, or `factory`. When a chain runs several
verifiers, the tag form selects which one — `verifier` alone is ambiguous and the script
reverts.

The accept leg is never generated on the incoming holder's behalf. Whoever is receiving
the role runs the script themselves in whichever mode fits their wallet — a Safe generates
a batch and imports it; an EOA runs the same script in EOA mode with `--broadcast`. They can equally just call `acceptOwnership()` from their own tooling, since
the propose leg already made them the pending holder.

## storageLocationsAdmin

```bash
TAG=0x00010001   # example — substitute your catalogued tag
export OUTPUT_MODE=SAFE
export SAFE_ADDRESS=0x<current admin Safe>

forge script script/ownership/TransferStorageLocationsAdmin.s.sol \
  --sig "run(string,bytes4)" sepolia $TAG --rpc-url $SEPOLIA_RPC_URL

export SAFE_ADDRESS=0x<incoming admin Safe>

forge script script/ownership/AcceptStorageLocationsAdmin.s.sol \
  --sig "run(string,bytes4)" sepolia $TAG --rpc-url $SEPOLIA_RPC_URL
```

This is a **separate role from the owner** with its own two-step transfer, scoped per
verifier tag. Moving ownership does not move it, and moving it does not move ownership. The
owner cannot move it either — `transferStorageLocationsAdmin` reverts
`OnlyCallableByStorageLocationsAdmin` for anyone but the current admin, so there is no
owner override if the admin key is lost.

## The transitional roles are not two-step

`allowlistAdmin` and `feeAggregator` live in the verifier's `DynamicConfig` and are
re-pointed directly via `SetDynamicConfig` (with the verifier's `versionTag`). There is
no propose/accept.

Because they are a single-step overwrite, re-point them **only after** the corresponding
ownership acceptance is confirmed on-chain. Handover order is
**grant-new-before-revoke-old**.

## Order is enforced by the contracts

You cannot lock a contract by executing these out of order. `acceptOwnership()` reverts
for any caller who is not the pending holder, and the pending holder is only set by
`transferOwnership`. An early accept simply fails.

What you *can* do is strand a transfer half-finished — proposed but never accepted. Until
acceptance, the **previous** owner still holds the role. Confirm each acceptance on-chain
before revoking anything.

## Check the result

`SnapshotRoles` reads every live role holder for review, and `DriftCheck` compares them
against `config/roles/<alias>.json`. See [Governance checks](governance.md).
