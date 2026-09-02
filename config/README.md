# `config/` — config-as-data

Every deployment/config parameter lives here as JSON. The scripts under `script/` are generic loops that read these files, so one script serves every lane and chain you add here, with nothing hardcoded.

Three categories:

| Dir            | One file per… | Purpose |
|----------------|---------------|---------|
| `version-tags.json` | repo     | the catalog of every verifier `versionTag` in use (cross-chain identities, one spelling everywhere) |
| `chains/`      | chain         | deploy-time inputs: RMN address, storage locations (aggregator URL), CREATE2 resolver salt |
| `lanes/`       | directed lane | per-lane config: `versionTag` (which verifier serves the lane), signer set + threshold, verification fee, router, allowlist |
| `roles/`       | chain         | roles-as-data: the intended holder of every privileged role (owner, admins, fee aggregators) |

Files ending in `.example.json` are illustrative. Files starting with `_template`
document the full schema. Real per-deployment files should be named by the chain
alias (`sepolia.json`) or lane (`sepolia-to-base_sepolia.json`).

---

## `chains/<alias>.json`

```jsonc
{
  "alias":            "sepolia",              // stable key; matches rpc_endpoints + roles file
  "chainId":          11155111,
  "chainSelector":    "16015286601757825753", // CCIP chain selector (string: exceeds JS safe int)
  "rmn":              "0x...",                 // Chainlink-provided RMN address. MUST be non-zero.
  "router":           "0x...",                 // Chainlink's local CCIP router; synced from the API. Lanes inherit it unless they override.
                                               // Synced fields: router, rmn, chainId, feeTokens, explorerAddressPath.
  "finalityConfig":   "0x00000001",            // bytes4 FinalityCodec value. ⚠️ PLACEHOLDER — see note below.
  "storageLocations": ["https://aggregator.<operator>.example/ccv"], // operator's OWN aggregator endpoint(s)
  "feeTokens":        ["0x..."],               // fee tokens to report on / sweep. Empty => fee scripts no-op.
  "resolverSalt":     "0x0000...0001",         // CREATE2 salt for the resolver. MUST be identical on every chain.
  "explorerAddressPath": "https://sepolia.etherscan.io/address" // Synced from the API (chainMetadata.explorer.addressPath).
                                                     // A FULL URL prefix, not a path fragment: deployments-report.sh
                                                     // links addresses as <explorerAddressPath>/<addr>.
                                                     // Empty or absent => plain unlinked addresses.
}
```

> `feeTokens` drives `BalanceReport` (reads `balanceOf` for the verifier and resolver)
> and `SweepFees` (passes the list to `withdrawFeeTokens`). The key is **optional by
> design**: fee sweeping is opt-in per chain, so a chain whose list is not decided yet still
> loads for every other script — an absent or empty list makes both fee scripts a logged
> no-op rather than an error. The set of tokens that can actually accrue is governed by
> CCIP's `FeeQuoter`; this list mirrors it, synced from the CCIP API by
> `script/config/sync-ccip-config.sh` rather than maintained by hand.
> `SweepFees` filters the list by current balance: tokens reading zero at build time are
> omitted from the staged call, and a contract with nothing to sweep gets no call at all.
> Set `SKIP_ZERO_BALANCES=false` to stage every listed token regardless of balance — for
> Safe batches executed long after they are built, where fees may accrue in between.
>
> **Lean append-only; prune deliberately.** Read this field as "every token that could
> hold a balance here", not "tokens Chainlink supports today" — de-supporting a token does
> not zero a balance already sitting on the verifier, and `withdrawFeeTokens` is its only
> exit. Removing an entry is reversible (re-add it and sweep), but any balance arriving
> after removal sits unswept and invisible until someone remembers to. Prune a token only
> once nothing more can arrive: the FeeQuoter no longer supports it, both contracts read
> zero in `BalanceReport`, and no in-flight messages could still pay fees in it. Until
> then a stale entry costs one `balanceOf` per sweep and is skipped silently at zero.
>
> ⚠️ Every entry must be a real ERC20 **with code**. A zero address, a codeless address,
> or a `balanceOf` that reverts fails the `SweepFees` build with the offending entry named —
> a broken entry is a misconfiguration, never treated as an empty balance. `BalanceReport`
> flags such an entry as `UNREADABLE`.

> **`finalityConfig` defaults to `0x00000000`.** It is the `bytes4` ALLOWED finality
> (FinalityCodec) set on the verifier via `setAllowedFinalityConfig`. Encoding:
> `0x00000000` = wait for full finality (safest, production default); the low 16 bits are
> a block depth (`0x00000001` = depth-1, the fast path Chainlink uses for staging tests);
> bit 16 (`0x00010000`) is the `safe`-tag flag.

Notes:
- `storageLocations` is a **cross-workstream input** from the off-chain/infra team
  (the deployed aggregator hostname). It is per-operator and cannot be hardcoded.
  The deploy should not block on it — it can be set/updated later via the
  `UpdateStorageLocations` script (caller is the `storageLocationsAdmin`, not the owner).
- `resolverSalt` must be the **same value on every chain** for the resolver to get
  the same address everywhere. The factory itself gets address parity from a
  fresh nonce-0 deployer (CREATE, not CREATE2) — it has no salt.
- `versionTag` is NOT chain state. It is a deploy input: `DeployVerifier` takes the tag
  as an argument (`--sig "run(string,bytes4)" <alias> 0x00010001`) and appends the new
  verifier to `deployments/<alias>.json`. Each lane pins the verifier serving it via
  its own mandatory `versionTag`.

## `lanes/<source>-to-<dest>.json`

A **directed** lane (source → dest). Contracts deploy on both chains of every lane.

```jsonc
{
  "name":   "sepolia-to-base_sepolia",
  "source": { "alias": "sepolia",      "chainSelector": "16015286601757825753" },
  "dest":   { "alias": "base_sepolia", "chainSelector": "10344971235874465080" },

  // MANDATORY: which verifier serves this lane, on BOTH legs (the dest
  // verifier rejects any tag != its own immutable tag, so source tag == dest tag).
  // The versionTag must be recorded in deployments/<alias>.json on both endpoints.
  // Upgrades are per-lane, reviewed diffs: flip this tag, then re-run the configure
  // scripts (ApplyOutbound cutover last).
  "versionTag": "0x00010001",

  // -> applySignatureConfigs, keyed by SOURCE chain selector (inbound verification set).
  //    Full-set REPLACEMENT every time — list the complete desired signer set.
  //    Constraint: not 1-of-1, threshold must exceed 2/3 (e.g. 10 signers -> threshold 7).
  "signatureConfig": {
    "threshold": 7,
    "signers": ["0x...", "0x..."]
  },

  // -> applyRemoteChainConfigUpdates, keyed by DEST chain selector (outbound).
  //    `router` is OPTIONAL: absent inherits the SOURCE chain's synced router
  //    (chains/<alias>.json, maintained by script/config/sync-ccip-config.sh).
  //    An explicit 0x0 PAUSES the lane — the only emergency lever (outbound).
  "remoteChainConfig": {
    "feeUSDCents":        0,
    "gasForVerification": 200000,
    "payloadSizeBytes":   0
  },

  // -> applyAllowlistUpdates, keyed by DEST chain selector.
  "allowlist": {
    "allowlistEnabled":         false,
    "addedAllowlistedSenders":   [],
    "removedAllowlistedSenders": []
  }
}
```

> ⚠️ **Direction mapping is an OPEN ITEM to confirm against Chainlink's own Go
> sequence** `configure_committee_verifier_for_lanes.go`. The mapping above
> (signature config keyed by source, remote/allowlist keyed by dest) is the
> working assumption; verify which side each call is executed on before a real run.

## `roles/<alias>.json`

Machine-checkable intent for the drift-check script (outline step 16). Verifier roles
are PER DEPLOYMENT, keyed by `versionTag` like the deployment record — declare a new
verifier's entry BEFORE deploying it (`DeployVerifier` reads it to set DynamicConfig
and propose the handovers, and refuses a tag with no entry).

```jsonc
{
  "alias": "sepolia",
  "verifiers": [
    {
      "versionTag":            "0x00010001", // matches deployments/<alias>.json
      "owner":                 "0x...",  // 2-step ownable
      "storageLocationsAdmin": "0x...",  // separate 2-step admin role
      "allowlistAdmin":        "0x...",  // part of DynamicConfig
      "feeAggregator":         "0x..."   // DynamicConfig.feeAggregator (distinct from resolver's!)
    }
  ],
  "resolver": {
    "owner":         "0x...",          // 2-step ownable
    "feeAggregator": "0x..."           // resolver setFeeAggregator (a SECOND, distinct fee destination)
  },
  "factory": {
    "owner": "0x..."                    // transferred to governance after bootstrap
  }
}
```

`DriftCheck` compares every RECORDED verifier against ITS entry; a recorded
verifier without one is drift. Delete an entry together with its deployment record
when the verifier retires.

## `version-tags.json`

The repo-wide catalog of every `versionTag` in use. Tags are CROSS-CHAIN identities (a
lane's tag must match on both endpoints), so the catalog is one file, not per chain:
one spelling everywhere. `DeployVerifier` refuses to deploy an uncataloged tag, and a
lane may only pin a catalogued one. Entries follow the documented scheme — 2 bytes
operator id + 2 bytes version, both halves non-zero — which the loader enforces here
(the contracts themselves treat the tag as an opaque `bytes4`).

```jsonc
{
  "versionTags": [
    { "tag": "0x00010001", "description": "committee verifier v1" }
  ]
}
```

## `deployments/<alias>.json`

The record of deployed artifacts, written by the deploy scripts. The `verifiers` array
maps each DEPLOYED catalogued versionTag to its address on this chain — the stored
mirror of the resolver's inbound map: one entry per live verifier, tags unique per
chain. `DeployVerifier` APPENDS an entry per deploy (a duplicate tag reverts;
`ALLOW_TAG_REPLACE=true` replaces that entry, for redoing a deploy that went wrong
before anything referenced it — never while it carries traffic).

```jsonc
{
  "alias":    "sepolia",
  "factory":  "0x...",
  "resolver": "0x...",                       // the stable lane-facing CCV identity
  "verifiers": [
    { "versionTag": "0x00010001", "address": "0x..." },  // old verifier keeps verifying in-flight messages
    { "versionTag": "0x00010002", "address": "0x..." }   // new verifier, pinned by lanes as they migrate
  ]
}
```

Retiring a verifier once its lanes have drained: stage an inbound update of
`{tag, address(0)}` on the resolver, then delete the entry from the record.
`DriftCheck` compares the inbound map closed-world, so an entry left in only one of
the two places is reported as drift.

