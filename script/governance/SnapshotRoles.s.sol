// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// vm.serializeX accumulates into the object; only the final call returns the JSON.
// forge-lint: disable-start(unused-return)

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CREATE2Factory} from "@chainlink/contracts-ccip/contracts/CREATE2Factory.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
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
/// @dev Read-only on-chain: no broadcasting. Run without --broadcast. Extends BaseScript
///      for its shared preflights only; the staging plumbing goes unused.
/// @dev There is no `pendingOwner()` getter on these contracts, so a half-finished
///      two-step ownership handover cannot be captured. The verifier's pending
///      storage-locations admin IS readable and is reported to the console (it has no
///      home in the roles schema, which records settled state only).
///
/// Usage:
///   forge script script/governance/SnapshotRoles.s.sol --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
contract SnapshotRoles is BaseScript {
  function run(
    string calldata chainAlias
  ) external {
    // A snapshot from the wrong RPC could be promoted into config/roles — refuse it.
    ConfigLib.assertChain(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    require(
      deployment.verifiers.length > 0 && deployment.resolver != address(0), "SnapshotRoles: contracts not deployed"
    );
    // Reachability, checked up front for a legible message: a typed call to a codeless
    // address fails with an ABI-decode error that try/catch cannot name.
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      _assertReachable(
        deployment.verifiers[i].addr,
        string.concat("verifier ", ConfigLib.tagToString(deployment.verifiers[i].versionTag))
      );
    }
    _assertReachable(deployment.resolver, "resolver");

    Types.RolesConfig memory roles = snapshot(deployment);

    console2.log("[SnapshotRoles] chain:", chainAlias);
    for (uint256 i = 0; i < roles.verifiers.length; ++i) {
      console2.log("  verifier versionTag:           ", ConfigLib.tagToString(roles.verifiers[i].versionTag));
      console2.log("    owner:                ", roles.verifiers[i].owner);
      console2.log("    storageLocationsAdmin:", roles.verifiers[i].storageLocationsAdmin);
      console2.log("    allowlistAdmin:       ", roles.verifiers[i].allowlistAdmin);
      console2.log("    feeAggregator:        ", roles.verifiers[i].feeAggregator);

      address pendingAdmin = CommitteeVerifier(deployment.verifiers[i].addr).getPendingStorageLocationsAdmin();
      if (pendingAdmin != address(0)) {
        console2.log("    NOTE pending storageLocationsAdmin (handover in flight):", pendingAdmin);
      }
    }
    console2.log("  resolver owner:                ", roles.resolver.owner);
    console2.log("  resolver feeAggregator:        ", roles.resolver.feeAggregator);
    if (deployment.factory != address(0)) {
      console2.log("  factory owner:                 ", roles.factoryOwner);
    } else {
      console2.log("  factory owner:                  (no factory recorded for this chain)");
    }

    string memory path = writeSnapshot(chainAlias, roles);
    console2.log("[SnapshotRoles] written:", path);
    console2.log(
      string.concat("[SnapshotRoles] review, then promote: cp ", path, " config/roles/", chainAlias, ".json")
    );
  }

  /// @notice THE test seam. Reads every live role for a deployment, one roles entry per
  ///         recorded verifier.
  /// @dev Typed calls, not raw staticcalls: a missing getter or an undeployed address
  ///      must abort the snapshot rather than silently record `address(0)` as if it
  ///      were the real owner. Writing a zeroed roles file would be worse than failing.
  function snapshot(
    Types.Deployment memory deployment
  ) public view returns (Types.RolesConfig memory roles) {
    roles.aliasName = deployment.aliasName;

    roles.verifiers = new Types.VerifierRoles[](deployment.verifiers.length);
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      CommitteeVerifier verifier = CommitteeVerifier(deployment.verifiers[i].addr);
      CommitteeVerifier.DynamicConfig memory dynamicConfig = verifier.getDynamicConfig();
      roles.verifiers[i] = Types.VerifierRoles({
        versionTag: deployment.verifiers[i].versionTag,
        owner: verifier.owner(),
        storageLocationsAdmin: verifier.getStorageLocationsAdmin(),
        allowlistAdmin: dynamicConfig.allowlistAdmin,
        feeAggregator: dynamicConfig.feeAggregator
      });
    }

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
  /// @dev The verifiers array is assembled by hand: vm.serialize* handles scalars only,
  ///      not arrays of objects (same approach as `ConfigLib.writeDeploymentByPath`).
  /// @return path The file written.
  function writeSnapshot(
    string memory chainAlias,
    Types.RolesConfig memory roles
  ) public returns (string memory path) {
    string memory entries = "";
    for (uint256 i = 0; i < roles.verifiers.length; ++i) {
      string memory entry = string.concat(
        "{\"versionTag\":\"",
        ConfigLib.tagToString(roles.verifiers[i].versionTag),
        "\",\"owner\":\"",
        vm.toString(roles.verifiers[i].owner),
        "\",\"storageLocationsAdmin\":\"",
        vm.toString(roles.verifiers[i].storageLocationsAdmin),
        "\",\"allowlistAdmin\":\"",
        vm.toString(roles.verifiers[i].allowlistAdmin),
        "\",\"feeAggregator\":\"",
        vm.toString(roles.verifiers[i].feeAggregator),
        "\"}"
      );
      entries = string.concat(entries, i == 0 ? "" : ",", entry);
    }
    string memory verifiersJson = string.concat("[", entries, "]");

    string memory resolverObject = "resolver";
    vm.serializeAddress(resolverObject, "owner", roles.resolver.owner);
    string memory resolverJson = vm.serializeAddress(resolverObject, "feeAggregator", roles.resolver.feeAggregator);

    string memory factoryObject = "factory";
    string memory factoryJson = vm.serializeAddress(factoryObject, "owner", roles.factoryOwner);

    // vm.serializeString embeds a nested JSON OBJECT as JSON but not an array, so the
    // root is assembled by hand around the two serialized objects.
    string memory json = string.concat(
      "{\"alias\":\"",
      chainAlias,
      "\",\"verifiers\":",
      verifiersJson,
      ",\"resolver\":",
      resolverJson,
      ",\"factory\":",
      factoryJson,
      "}"
    );

    vm.createDir("out/governance", true); // idempotent; survives a fresh clone
    // out/governance/ is gitignored wholesale (live role addresses); the block number
    // keeps successive snapshots from clobbering each other.
    path = string.concat("out/governance/", chainAlias, "-", vm.toString(block.number), ".roles.local.json");
    vm.writeJson(json, path);
  }
}
