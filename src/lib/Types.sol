// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Types
/// @notice Plain data structs mirroring the JSON schema under `config/`.
/// @dev Kept deliberately decoupled from the Chainlink contract structs so the
///      config layer has no compile dependency on the contracts. The configure/
///      scripts translate these into the exact Chainlink argument structs
///      (e.g. SignatureQuorumValidator.SignatureConfig) at the call site.
library Types {
  // ----------------------------- config/chains ------------------------------
  struct ChainConfig {
    string aliasName; // stable key; matches rpc alias + roles/deployment files
    uint256 chainId;
    uint64 chainSelector; // parsed from a JSON string (selectors exceed 2^53)
    address rmn; // Chainlink-provided; MUST be non-zero
    bytes4 versionTag; // non-zero, immutable
    bytes4 finalityConfig; // FinalityCodec bytes4; 0x00000000 = full finality. TODO PLACEHOLDER value (TBD).
    string[] storageLocations; // operator's own aggregator endpoint(s)
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
    bool allowlistEnabled;
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
    SignatureConfig sig;
    RemoteChainConfig remote;
    AllowlistConfig allowlist;
  }

  // ------------------------------ config/roles ------------------------------
  struct VerifierRoles {
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
    VerifierRoles verifier;
    ResolverRoles resolver;
    address factoryOwner;
  }

  // --------------------------- config/deployments ---------------------------
  struct Deployment {
    string aliasName;
    address factory;
    address resolver;
    address verifier;
  }
}