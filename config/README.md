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
  "versionTag":       "0xAABBCCDD",            // bytes4, non-zero, immutable. Scheme: 2 bytes operator id + 2 bytes version.
  "finalityConfig":   "0x00000001",            // bytes4 FinalityCodec value. ⚠️ PLACEHOLDER — see note below.
  "storageLocations": ["https://aggregator.<operator>.example/ccv"], // operator's OWN aggregator endpoint(s)
  "resolverSalt":     "0x0000...0001"          // CREATE2 salt for the resolver. MUST be identical on every chain.
}
```

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
  //    router = 0x0 is the ONLY emergency lever (outbound pause) — see README.
  "remoteChainConfig": {
    "router":             "0x...",
    "allowlistEnabled":   false,
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