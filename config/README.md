# `config/` — config-as-data

Every deployment/config parameter lives here as JSON. The scripts under `script/`
are generic loops that read these files, so the same script serves all 8 lanes
(and any future chain) with nothing hardcoded.

Three categories:

| Dir            | One file per… | Purpose |
|----------------|---------------|---------|
| `chains/`      | chain         | deploy-time inputs: RMN address, `versionTag`, storage locations (aggregator URL), CREATE2 resolver salt |
| `lanes/`       | directed lane | per-lane config: signer set + threshold, verification fee, router, allowlist |
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
  "versionTag":       "0xAABBCCDD",            // bytes4, non-zero, immutable. Scheme: 2 bytes operator id + 2 bytes version.
  "finalityConfig":   "0x00000001",            // bytes4 FinalityCodec value. ⚠️ PLACEHOLDER — see note below.
  "storageLocations": ["https://aggregator.<operator>.example/ccv"], // operator's OWN aggregator endpoint(s)
  "feeTokens":        ["0x..."],               // fee tokens to report on / sweep. Empty => fee scripts no-op.
  "resolverSalt":     "0x0000...0001",         // CREATE2 salt for the resolver. MUST be identical on every chain.
  "explorerUrl":      "https://sepolia.etherscan.io" // OPTIONAL, operator-maintained; not served by the API, never synced.
                                                     // deployments-report.sh links addresses as <explorerUrl>/address/<addr>;
                                                     // empty or absent => plain unlinked addresses.
}
```

> `feeTokens` drives `BalanceReport` (reads `balanceOf` for the verifier and resolver)
> and `SweepFees` (passes the list to `withdrawFeeTokens`). The key is **optional by
> design**: fee sweeping is opt-in per chain, so a chain whose list is not decided yet still
> loads for every other script — an absent or empty list makes both fee scripts a logged
> no-op rather than an error. The set of tokens that can actually accrue is governed by
> CCIP's `FeeQuoter`; this list mirrors it, synced from the CCIP API by
> `script/config/sync-ccip-config.sh` rather than maintained by hand.
> The list is *not* filtered by current balance —
> `SweepFees` builds Safe batches that execute later, and filtering on today's balance
> would silently drop fees accruing in between. `SKIP_ZERO_BALANCES=1` optionally skips a
> WHOLE contract whose every listed token reads zero at build time (saves a no-op tx); the
> list inside the call is never shrunk. Off by default: an unreadable balance counts as
> zero, so the flag can silently miss a sweep.
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
> ⚠️ Every entry must be a real ERC20 **with code**. `balanceOf` on a codeless address
> reverts the whole `withdrawFeeTokens` call, so one typo blocks every future sweep for that
> chain. `BalanceReport` flags such an entry as `UNREADABLE`.

> ⚠️ **`finalityConfig` is a PLACEHOLDER pending a decision.** It is the `bytes4`
> ALLOWED finality (FinalityCodec) set on the verifier via `setAllowedFinalityConfig`.
> Encoding: `0x00000000` = wait for full finality (safest, production default); the
> low 16 bits are a block depth (`0x00000001` = depth-1, the fast path Chainlink uses
> for staging tests); bit 16 (`0x00010000`) is the `safe`-tag flag. The staging config
> currently uses `0x00000001` so the fast-path test messages are permitted. TODO: revisit
> before production (likely `0x00000000`).

Notes:
- `storageLocations` is a **cross-workstream input** from the off-chain/infra team
  (the deployed aggregator hostname). It is per-operator and cannot be hardcoded.
  The deploy should not block on it — it can be set/updated later via the
  `UpdateStorageLocations` script (caller is the `storageLocationsAdmin`, not the owner).
- `resolverSalt` must be the **same value on every chain** for the resolver to get
  the same address everywhere. The factory itself gets address parity from a
  fresh nonce-0 deployer (CREATE, not CREATE2) — it has no salt.
- `versionTag` is immutable. A new tag ⇒ a new verifier deployment + resolver re-wiring.

## `lanes/<source>-to-<dest>.json`

A **directed** lane (source → dest). Contracts deploy on both chains of every lane.

```jsonc
{
  "name":   "sepolia-to-base_sepolia",
  "source": { "alias": "sepolia",      "chainSelector": "16015286601757825753" },
  "dest":   { "alias": "base_sepolia", "chainSelector": "10344971235874465080" },

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

Machine-checkable intent for the drift-check script (outline step 16).

```jsonc
{
  "alias": "sepolia",
  "verifier": {
    "owner":                 "0x...",  // 2-step ownable
    "storageLocationsAdmin": "0x...",  // separate 2-step admin role
    "allowlistAdmin":        "0x...",  // part of DynamicConfig
    "feeAggregator":         "0x..."   // DynamicConfig.feeAggregator (distinct from resolver's!)
  },
  "resolver": {
    "owner":         "0x...",          // 2-step ownable
    "feeAggregator": "0x..."           // resolver setFeeAggregator (a SECOND, distinct fee destination)
  },
  "factory": {
    "owner": "0x..."                    // transferred to governance after bootstrap
  }
}
```