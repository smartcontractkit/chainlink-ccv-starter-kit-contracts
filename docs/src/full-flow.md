# Full flow example

This page is the path: the end-to-end sequence as copy-paste commands. Follow it top to
bottom — each step ends with a link to the chapter that explains it in depth, for when
you want the why.

One worked example for a single bidirectional lane: **Sepolia ↔ Base Sepolia**. The
aliases, selectors, RPC variables and `TAG` below are this example's — substitute your
own.

**What this page covers:** install → config → deploy → configure → governance checks →
**accept handover**.
**Not on this page:** fee sweeping or ongoing CCIP config sync — see
[Operational notes](operations.md) when you need those.

In a typical production run, `config/roles/*.json` names non-deployer holders (often a
Safe). Deploy **proposes** those roles on chain; each incoming holder **accepts** at some
point after that — this walkthrough places it last, but acceptance can equally happen
before or between the configure steps. The only rule is that each configure call is
signed by whoever holds the role **at that moment**: the deployer until acceptance
(EOA mode works), the new holder after it (typically `OUTPUT_MODE=SAFE`). Until every
acceptance lands, drift will show pending transfers.

Only one ordering is enforced anywhere: **the three deploy steps, per chain** (factory →
resolver → verifier). Everything in the configure step writes disjoint state, can run in
any order, and is safe to re-run.

```bash
export TAG=0x00010001    # this example's tag — pick your own; catalog it and use it on both lane endpoints
```

Configure and ownership steps run through `make` targets; each takes
`OUTPUT_MODE=EOA` (broadcast now) or `OUTPUT_MODE=SAFE SAFE_ADDRESS=0x…` (stage a Safe
batch) — there is no default. This walkthrough uses `EOA`.

## 0. One-time setup

```bash
make install        # npm ci + git submodules
cp .env.example .env    # fill in SEPOLIA_RPC_URL, BASE_SEPOLIA_RPC_URL, signing config
cp config/version-tags.example.json config/version-tags.json   # ensure $TAG is listed
make build
```

→ [Getting started](getting-started.md)

## 1. Write the config

```bash
# Chainlink's values, fetched — never typed. requires: CHAIN, SELECTOR (make discover lists them)
make add-chain CHAIN=sepolia      SELECTOR=16015286601757825753
make add-chain CHAIN=base_sepolia SELECTOR=10344971235874465080

# then hand-fill the operator fields each bootstrap lists as "still to fill in":
#   resolverSalt (same value on BOTH chains), storageLocations
# allowedFinality starts as {} (full finality only) and needs no edit unless a fast path is wanted
```

And create by hand, from the templates in `config/`:

- `config/lanes/sepolia-to-base_sepolia.json` and `config/lanes/base_sepolia-to-sepolia.json`
  — lanes are **directed**, a bidirectional pair is two files; each must use the same
  `"versionTag"` as `$TAG` on both endpoints
- `config/roles/sepolia.json` and `config/roles/base_sepolia.json` — each needs a
  `verifiers[]` entry for `$TAG` **before** deploy

**Decide the roles before deploying** — the deploy scripts consume them, they are not
applied later: factory and resolver ownership is *proposed to* `factory.owner` /
`resolver.owner` at deploy time, and the verifier bakes `feeAggregator` and
`allowlistAdmin` from the roles entry into its constructor. `DeployVerifier` refuses to run
while `verifier.owner`, `verifier.storageLocationsAdmin`, or `verifier.feeAggregator` is
unset for the tag — see [its preconditions](deploy.md#3-deploy-the-verifier). (Leaving
`factory.owner` / `resolver.owner` as the deployer is fine — ownership then just stays
put until a later [handover](handover.md).)

**Check the config before spending gas** — no RPC, no keys needed:

```bash
# every config file parses + lanes agree with chains, roles and the tag catalog
make validate-config

# per lane: selectors vs chain configs, salt identical, gasForVerification non-zero
#   (pre-deploy it notes the missing deployment records and skips those comparisons)
make parity-config LANE=sepolia-to-base_sepolia
make parity-config LANE=base_sepolia-to-sepolia

# the fetched Chainlink fields still match the API
make sync-check
```

→ [Configuration](configuration.md), [where the Chainlink fields come from](configuration.md#where-the-chainlink-fields-come-from)

## 2. Deploy — per chain, fixed order

Read these two before running anything below. Both are unrecoverable after the fact.

> **The deployer must be at nonce 0 on each chain.** `bootstrap-factory` must be its first
> ever transaction there. If it is not, the script refuses — and if the factory deploy
> itself fails *after* broadcasting, the nonce is no longer 0 and that chain can never get
> the parity address from this account. There is no retry for that.
>
> A later transaction in the same run failing is **not** that case. `bootstrap-factory`
> broadcasts two transactions when `factory.owner` is neither unset nor the deployer: the
> deploy, then the ownership proposal. If the deploy landed and the proposal did not, the
> factory is at the right address and owned by the deployer — finish it with
> [`TransferOwnership`](handover.md), and do not re-run bootstrap, which will now
> correctly refuse on the nonce check.

> **Double-check `rmn` in each chain config before `deploy-verifier`.** It is a
> constructor argument, immutable, and has no getter — no check in this repo can ever
> read it back. A wrong value means redeploying the verifier.

> **Use the `make` targets below.** They always `--broadcast`; a run that does not
> broadcast writes no deployment record, so it can never leave one behind for a contract
> that was not deployed.

```bash
# requires: CHAIN, RPC_URL (+ TAG for deploy-verifier) — broadcasts with SIGNER (default --aws)
make bootstrap-factory CHAIN=sepolia RPC_URL=$SEPOLIA_RPC_URL
make deploy-resolver   CHAIN=sepolia RPC_URL=$SEPOLIA_RPC_URL
make deploy-verifier   CHAIN=sepolia TAG=$TAG RPC_URL=$SEPOLIA_RPC_URL

make bootstrap-factory CHAIN=base_sepolia RPC_URL=$BASE_SEPOLIA_RPC_URL
make deploy-resolver   CHAIN=base_sepolia RPC_URL=$BASE_SEPOLIA_RPC_URL
make deploy-verifier   CHAIN=base_sepolia TAG=$TAG RPC_URL=$BASE_SEPOLIA_RPC_URL
```

Each deploy script also **proposes** ownership (and `storageLocationsAdmin` on the
verifier) to the addresses in `config/roles/<alias>.json`. That is not the end of
handover — incoming holders must still run the accept scripts in step 5 unless every
configured holder is the deployer.

**Checkpoint after the second resolver**: the resolver address must be identical on both
chains. `make deployments-check` asserts it from the recorded deployments. Do not
configure anything on top of a diverged resolver.

→ [Deploying](deploy.md)

## 3. Configure — per chain, grouped by caller

Run on **each chain** (`sepolia`, then `base_sepolia`). Order within a chain does not
matter. Each script maps to **one** privileged on-chain call and **one** role — there is
no combined script to split; the grouping below is by **who must sign**, not by script
file.

Use the signer that holds that role on the chain you are configuring. When every role in
`config/roles/<alias>.json` is still the deployer (typical testnet, before handover), the
same `--aws` key works for every block. When roles differ — or after handover — run each
block with that role's key or generate a Safe batch (`OUTPUT_MODE=SAFE`) from that holder.

Per-verifier scripts take `$TAG`; resolver scripts take only the chain alias.

### Sepolia — verifier owner

```bash
# requires: CHAIN, TAG, RPC_URL, OUTPUT_MODE (+ SAFE_ADDRESS in SAFE mode)
export TAG=0x00010001

make apply-remote-config     CHAIN=sepolia TAG=$TAG RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
make apply-signature-configs CHAIN=sepolia TAG=$TAG RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
make set-finality-config     CHAIN=sepolia TAG=$TAG RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
```

Two configure scripts are **not needed on a fresh deploy**: the constructor already set
the dynamic config (from the roles file) and `storageLocations` (from the chain config).
`SetDynamicConfig` and `UpdateStorageLocations` are change operations for later — see
[what a fresh deploy already has](configure.md#what-a-fresh-deploy-already-has).

### Sepolia — verifier owner or `allowlistAdmin`

```bash
# requires: CHAIN, TAG, RPC_URL, OUTPUT_MODE
make apply-allowlists CHAIN=sepolia TAG=$TAG RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
```

### Sepolia — resolver owner

```bash
# requires: CHAIN, RPC_URL, OUTPUT_MODE — no TAG
make apply-outbound     CHAIN=sepolia RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
make apply-inbound      CHAIN=sepolia RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
make set-fee-aggregator CHAIN=sepolia RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
```

### Base Sepolia

Repeat the three blocks above with `base_sepolia`, `$TAG`, and `$BASE_SEPOLIA_RPC_URL`.

Each script still covers every lane that touches that chain in one run. To route a block
through a Safe instead of `--aws`, swap `OUTPUT_MODE=EOA` for
`OUTPUT_MODE=SAFE SAFE_ADDRESS=0x…` on the same targets — see
[Safe batches](safe-batches.md).

This walkthrough configures before handover, so the deployer signs everything — it stays
the active holder until the incoming party accepts. If a role was already accepted, run
that block as the new holder instead (`OUTPUT_MODE=SAFE` from their Safe).

→ [Configuring the contracts](configure.md)

## 4. Check before calling it live

```bash
# drift requires: CHAIN, RPC_URL — parity requires: LANE, SOURCE_RPC, DEST_RPC
make drift CHAIN=sepolia      RPC_URL=$SEPOLIA_RPC_URL
make drift CHAIN=base_sepolia RPC_URL=$BASE_SEPOLIA_RPC_URL

make parity LANE=sepolia-to-base_sepolia SOURCE_RPC=$SEPOLIA_RPC_URL      DEST_RPC=$BASE_SEPOLIA_RPC_URL
make parity LANE=base_sepolia-to-sepolia SOURCE_RPC=$BASE_SEPOLIA_RPC_URL DEST_RPC=$SEPOLIA_RPC_URL

make deployments-doc      # regenerate the deployed-addresses page, commit it
```

All exit `0` clean / `1` finding / `2` couldn't run.

→ [Governance checks](governance.md)

## 5. Hand over — accept ownership

Deploy already ran the propose leg for every two-step role in `config/roles/<alias>.json`
(factory owner, resolver owner, verifier owner, `storageLocationsAdmin`). This step is
only the **accept** leg — each incoming holder runs it with **their** key or Safe. It
sits last here, but nothing pins it there: accepting earlier just means the later
configure blocks are signed by the new holder.

### Skip this step when

Every role in both `config/roles/*.json` files points at the **deployer address** (or
`factory.owner` is unset). The deploy scripts keep or auto-accept those roles; nothing is
pending. That is fine for a solo testnet run; it is not the usual production shape.
Confirm with `make drift` — role holders should match the roles file with no pending
notes.

### Accept on each chain

Run each block only for roles that were **proposed to someone other than the deployer**.
The incoming holder runs these with **their** signer (EOA example below; Safe path in
[handover.md](handover.md)).

**Sepolia:**

```bash
# requires: CHAIN, TARGET (or TAG for accept-sla), RPC_URL, OUTPUT_MODE
export TAG=0x00010001   # same tag variable as above — substitute your own

# factory (if factory.owner != deployer)
make accept-owner CHAIN=sepolia TARGET=factory        RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA

# resolver (if resolver.owner != deployer — not needed when deployer was accepted in-place at deploy)
make accept-owner CHAIN=sepolia TARGET=resolver       RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA

# verifier owner (if verifiers[].owner != deployer)
make accept-owner CHAIN=sepolia TARGET=verifier:$TAG  RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA

# storageLocationsAdmin (if verifiers[].storageLocationsAdmin != deployer)
make accept-sla   CHAIN=sepolia TAG=$TAG              RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
```

**Base Sepolia** — same four targets with `base_sepolia` and `$BASE_SEPOLIA_RPC_URL`.

Re-run governance checks after acceptance:

```bash
make drift CHAIN=sepolia      RPC_URL=$SEPOLIA_RPC_URL
make drift CHAIN=base_sepolia RPC_URL=$BASE_SEPOLIA_RPC_URL
```

`feeAggregator` and `allowlistAdmin` are **not** two-step — they were set in the verifier
constructor from the roles file. Re-point them later with `SetDynamicConfig` only after
the new verifier owner has accepted.

**Done when:** every accept has landed, `make drift` is clean on both chains, and
on-chain owners/admins match `config/roles/*.json` (no pending ownership or
`storageLocationsAdmin` transfers).

→ [Handover](handover.md)
