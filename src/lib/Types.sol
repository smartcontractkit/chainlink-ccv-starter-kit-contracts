// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Types
/// @notice Plain data structs mirroring the JSON schema under `config/`.
/// @dev Kept deliberately decoupled from the Chainlink contract structs so the
///      config layer has no compile dependency on the contracts. The configure/
///      scripts translate these into the exact Chainlink argument structs
///      (e.g. SignatureQuorumValidator.SignatureConfig) at the call site.
/// @dev Adding a field here also means adding a comparison in `DriftCheck` and a case in
///      `DriftCheck.t.sol`. Nothing enforces that, so an uncompared field silently makes
///      the drift check incomplete.
/// @dev The recorded deploy params are exempt from that rule: they record what a past
///      deploy constructed, not declared intent, so differing from current config is
///      normal rather than drift.
library Types {
  // ----------------------------- config/chains ------------------------------
  struct ChainConfig {
    string aliasName; // stable key; matches rpc alias + roles/deployment files
    uint256 chainId;
    uint64 chainSelector; // parsed from a JSON string (selectors exceed 2^53)
    address rmn; // Chainlink-provided; MUST be non-zero
    address router; // Chainlink's local CCIP router, synced from the API; default for lanes
    bytes4 finalityConfig; // FinalityCodec bytes4. 0x00000000 (full finality only) is the default.
    string[] storageLocations; // operator's own aggregator endpoint(s)
    address[] feeTokens; // fee tokens to report on / sweep. Empty = no-op for fee scripts.
    bytes32 resolverSalt; // identical on every chain
  }

  // ------------------------------ config/lanes ------------------------------
  struct LaneEndpoint {
    string aliasName;
    uint64 chainSelector;
  }

  struct SignatureConfig {
    uint8 threshold;
    address[] signers; // FULL replacement set (no incremental add/remove)
  }

  struct RemoteChainConfig {
    address router; // router == address(0) is the outbound emergency lever
    uint16 feeUSDCents;
    uint32 gasForVerification;
    uint16 payloadSizeBytes;
  }

  struct AllowlistConfig {
    bool allowlistEnabled;
    address[] added;
    address[] removed;
  }

  struct LaneConfig {
    string name;
    LaneEndpoint source;
    LaneEndpoint dest;
    bytes4 versionTag;
    SignatureConfig signatureConfig;
    RemoteChainConfig remote;
    AllowlistConfig allowlist;
  }

  // ------------------------------ config/roles ------------------------------
  /// @dev Role holders for ONE verifier, keyed by its versionTag like the
  ///      deployment record. Declared BEFORE deploying that verifier.
  struct VerifierRoles {
    bytes4 versionTag;
    address owner;
    address storageLocationsAdmin;
    address allowlistAdmin;
    address feeAggregator;
  }

  struct ResolverRoles {
    address owner;
    address feeAggregator;
  }

  struct RolesConfig {
    string aliasName;
    VerifierRoles[] verifiers; // one entry per verifier; tags unique per chain
    ResolverRoles resolver;
    address factoryOwner;
    // The createAndCall allowlist the factory SHOULD hold: the desired full set, not a
    // delta. Absent means "not managed here" and is left alone; [] means nobody may
    // createAndCall.
    address[] factoryAllowlist;
  }

  // --------------------------- config/deployments ---------------------------
  // Deploy-time params are recorded beside each address: `encodedArgs` mirrors the plain
  // fields, both set from the same locals at the `new` call. The address is the presence
  // flag — zero means that contract is not deployed and its params carry no meaning.

  struct FactoryDeployParams {
    address deployer; // the nonce-0 EOA the CREATE address derives from
    address[] allowList;
    bytes encodedArgs; // abi.encode(allowList)
  }

  /// @dev The resolver takes no constructor arguments, so `encodedArgs` is always empty.
  ///      `salt` is not an argument either — it fixes the CREATE2 address, which makes it
  ///      the deploy-time input worth recording.
  struct ResolverDeployParams {
    bytes32 salt;
    bytes encodedArgs;
  }

  /// @dev One deployed verifier. Mirrors one entry of the resolver's
  ///      inbound map (bytes4 versionTag -> verifier); tags are unique per chain.
  struct VerifierDeployment {
    bytes4 versionTag; // immutable on-chain
    address addr;
    address feeAggregator; // DynamicConfig member; mutable on-chain afterwards
    address allowlistAdmin; // DynamicConfig member; mutable on-chain afterwards
    string[] storageLocations; // mutable on-chain afterwards
    address rmn; // immutable on-chain
    bytes encodedArgs; // abi.encode(dynamicConfig, storageLocations, rmn, versionTag)
  }

  struct Deployment {
    string aliasName;
    address factory;
    FactoryDeployParams factoryParams;
    address resolver;
    ResolverDeployParams resolverParams;
    // Which catalogued versionTags are DEPLOYED on this chain, and at what address.
    // config/version-tags.json enumerates the tag identities repo-wide; this record maps
    // the deployed ones to addresses.
    VerifierDeployment[] verifiers;
  }
}
