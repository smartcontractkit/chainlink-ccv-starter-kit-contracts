// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CREATE2Factory} from "@chainlink/contracts-ccip/contracts/CREATE2Factory.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title SnapshotRoles
/// @notice Bootstraps the roles-as-data file for a chain FROM LIVE
///         on-chain state, so an operator can capture the current reality and then
///         edit toward the desired intent.
/// @dev Writes to `out/governance/<alias>-<block>.roles.local.json` in the EXACT
///      `config/roles/<alias>.json` schema, so promotion is a copy. It deliberately
///      does NOT write into `config/` directly: that file records *intent*, and
///      overwriting it with current reality would erase the very difference
///      `DriftCheck` exists to find. (`foundry.toml` enforces this independently:
///      `config/` is mounted read-only except `config/deployments`.)
/// @dev The whole `out/governance/` tree is gitignored as a directory rule: a snapshot
///      holds live owner / fee-aggregator addresses, which the config-privacy policy
///      forbids committing, and a directory rule cannot be defeated by a rename.
/// @dev `<block>` in the filename — snapshots accumulate instead of clobbering, so the
///          record of who controlled what, when, survives. Keying on the observed block
///          rather than wall-clock makes it idempotent: re-running against the same block
///          rewrites an identical file, while any state change lands beside its
///          predecessor and stays diffable.
/// @dev Read-only on-chain: no broadcasting. Run without --broadcast.
/// @dev There is no `pendingOwner()` getter on these contracts, so a half-finished
///      two-step ownership handover cannot be captured. The verifier's pending
///      storage-locations admin IS readable and is reported to the console (it has no
///      home in the roles schema, which records settled state only).
///
/// Usage:
///   forge script script/governance/SnapshotRoles.s.sol --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
contract SnapshotRoles is Script {
  function run(
    string calldata chainAlias
  ) external {
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    require(
      deployment.verifier != address(0) && deployment.resolver != address(0), "SnapshotRoles: contracts not deployed"
    );

    Types.RolesConfig memory roles = snapshot(deployment);

    console2.log("[SnapshotRoles] chain:", chainAlias);
    console2.log("  verifier owner:                ", roles.verifier.owner);
    console2.log("  verifier storageLocationsAdmin:", roles.verifier.storageLocationsAdmin);
    console2.log("  verifier allowlistAdmin:       ", roles.verifier.allowlistAdmin);
    console2.log("  verifier feeAggregator:        ", roles.verifier.feeAggregator);
    console2.log("  resolver owner:                ", roles.resolver.owner);
    console2.log("  resolver feeAggregator:        ", roles.resolver.feeAggregator);
    if (deployment.factory != address(0)) {
      console2.log("  factory owner:                 ", roles.factoryOwner);
    } else {
      console2.log("  factory owner:                  (no factory recorded for this chain)");
    }

    address pendingAdmin = CommitteeVerifier(deployment.verifier).getPendingStorageLocationsAdmin();
    if (pendingAdmin != address(0)) {
      console2.log("  NOTE pending storageLocationsAdmin (handover in flight):", pendingAdmin);
    }

    string memory path = writeSnapshot(chainAlias, roles);
    console2.log("[SnapshotRoles] written:", path);
    console2.log(
      string.concat("[SnapshotRoles] review, then promote: cp ", path, " config/roles/", chainAlias, ".json")
    );
  }

  /// @notice THE test seam. Reads every live role for a deployment.
  /// @dev Typed calls, not raw staticcalls: a missing getter or an undeployed address
  ///      must abort the snapshot rather than silently record `address(0)` as if it
  ///      were the real owner. Writing a zeroed roles file would be worse than failing.
  function snapshot(
    Types.Deployment memory deployment
  ) public view returns (Types.RolesConfig memory roles) {
    roles.aliasName = deployment.aliasName;

    CommitteeVerifier verifier = CommitteeVerifier(deployment.verifier);
    roles.verifier.owner = verifier.owner();
    roles.verifier.storageLocationsAdmin = verifier.getStorageLocationsAdmin();

    CommitteeVerifier.DynamicConfig memory dynamicConfig = verifier.getDynamicConfig();
    roles.verifier.allowlistAdmin = dynamicConfig.allowlistAdmin;
    roles.verifier.feeAggregator = dynamicConfig.feeAggregator;

    VersionedVerifierResolver resolver = VersionedVerifierResolver(deployment.resolver);
    roles.resolver.owner = resolver.owner();
    roles.resolver.feeAggregator = resolver.getFeeAggregator();

    // Optional: not every chain records a factory (only the CREATE2 bootstrap chain
    // needs one long-term), so an absent factory is a zero, not a failure.
    if (deployment.factory != address(0)) {
      roles.factoryOwner = CREATE2Factory(deployment.factory).owner();
    }
  }

  /// @notice Serialises a roles snapshot in the `config/roles` schema.
  /// @return path The file written.
  function writeSnapshot(
    string memory chainAlias,
    Types.RolesConfig memory roles
  ) public returns (string memory path) {
    string memory verifierObject = "verifier";
    vm.serializeAddress(verifierObject, "owner", roles.verifier.owner);
    vm.serializeAddress(verifierObject, "storageLocationsAdmin", roles.verifier.storageLocationsAdmin);
    vm.serializeAddress(verifierObject, "allowlistAdmin", roles.verifier.allowlistAdmin);
    string memory verifierJson = vm.serializeAddress(verifierObject, "feeAggregator", roles.verifier.feeAggregator);

    string memory resolverObject = "resolver";
    vm.serializeAddress(resolverObject, "owner", roles.resolver.owner);
    string memory resolverJson = vm.serializeAddress(resolverObject, "feeAggregator", roles.resolver.feeAggregator);

    string memory factoryObject = "factory";
    string memory factoryJson = vm.serializeAddress(factoryObject, "owner", roles.factoryOwner);

    string memory root = "roles";
    vm.serializeString(root, "alias", chainAlias);
    vm.serializeString(root, "verifier", verifierJson);
    vm.serializeString(root, "resolver", resolverJson);
    string memory json = vm.serializeString(root, "factory", factoryJson);

    vm.createDir("out/governance", true); // idempotent; survives a fresh clone
    // out/governance/ is gitignored wholesale (live role addresses); the block number
    // keeps successive snapshots from clobbering each other.
    path = string.concat("out/governance/", chainAlias, "-", vm.toString(block.number), ".roles.local.json");
    vm.writeJson(json, path);
  }
}
