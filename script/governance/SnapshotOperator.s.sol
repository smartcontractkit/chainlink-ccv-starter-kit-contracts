// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// vm.serializeX accumulates into the object; only the final call returns the JSON.
// forge-lint: disable-start(unused-return)

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {FinalityConfigLib} from "../../src/lib/FinalityConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CREATE2Factory} from "@chainlink/contracts-ccip/contracts/CREATE2Factory.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {console2} from "forge-std/console2.sol";

/// @title SnapshotOperator
/// @notice Bootstraps the operator config file for a chain FROM LIVE on-chain state
///         (role holders and verifier settings), so an operator can capture the current
///         reality and then edit toward the desired intent.
/// @dev Writes to `out/governance/<alias>-<block>.operator.local.json` in the EXACT
///      `config/operator/chains/<alias>.json` schema, so promotion is a copy. It deliberately
///      does NOT write into `config/` directly: that file records *intent*, and
///      overwriting it with current reality would erase the very difference
///      `DriftCheck` exists to find. (`foundry.toml` enforces this independently:
///      `config/` is mounted read-only except `config/deployments`.)
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
///      home in the operator schema, which records settled state only).
///
/// Usage:
///   forge script script/governance/SnapshotOperator.s.sol --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
contract SnapshotOperator is BaseScript {
  function run(
    string calldata chainAlias
  ) external {
    // A snapshot from the wrong RPC could be promoted into config/operator/chains/<alias>.json - refuse it.
    ConfigLib.assertChain(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    require(
      deployment.verifiers.length > 0 && deployment.resolver != address(0), "SnapshotOperator: contracts not deployed"
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

    Types.OperatorConfig memory operator = snapshot(deployment);
    _carryOverCommittees(chainAlias, operator);

    console2.log("[SnapshotOperator] chain:", chainAlias);
    for (uint256 i = 0; i < operator.verifiers.length; ++i) {
      Types.VerifierConfig memory v = operator.verifiers[i];
      console2.log("  verifier versionTag:           ", ConfigLib.tagToString(v.versionTag));
      console2.log("    owner:                ", v.roles.owner);
      console2.log("    storageLocationsAdmin:", v.roles.storageLocationsAdmin);
      console2.log("    allowlistAdmin:       ", v.roles.allowlistAdmin);
      console2.log("    feeAggregator:        ", v.roles.feeAggregator);
      console2.log(
        "    allowedFinality:      ", FinalityConfigLib.describe(FinalityConfigLib.encode(v.allowedFinality))
      );
      console2.log("    storageLocations:     ", v.storageLocations.length);

      address pendingAdmin = CommitteeVerifier(deployment.verifiers[i].addr).getPendingStorageLocationsAdmin();
      if (pendingAdmin != address(0)) {
        console2.log("    NOTE pending storageLocationsAdmin (handover in flight):", pendingAdmin);
      }
    }
    console2.log("  resolver owner:                ", operator.resolver.roles.owner);
    console2.log("  resolver feeAggregator:        ", operator.resolver.roles.feeAggregator);
    if (deployment.factory != address(0)) {
      console2.log("  factory owner:                 ", operator.factory.roles.owner);
    } else {
      console2.log("  factory owner:                  (no factory recorded for this chain)");
    }

    string memory path = writeSnapshot(chainAlias, operator);
    console2.log("[SnapshotOperator] written:", path);
    console2.log(
      string.concat(
        "[SnapshotOperator] review, then promote: cp ", path, " config/operator/chains/", chainAlias, ".json"
      )
    );
  }

  /// @dev The committee that signs messages LEAVING this chain is applied on the
  ///      destinations, so it cannot be read here. An existing declaration is carried
  ///      over per tag; a chain with no file yet gets an empty one to fill in.
  function _carryOverCommittees(
    string memory chainAlias,
    Types.OperatorConfig memory operator
  ) private view {
    string memory existing = ConfigLib.operatorPath(chainAlias);
    if (!vm.exists(existing)) {
      console2.log("  NOTE signatureConfig left empty per verifier: declare the committee before promoting");
      return;
    }
    Types.OperatorConfig memory declared = ConfigLib.readOperatorByPath(existing);
    for (uint256 i = 0; i < operator.verifiers.length; ++i) {
      if (!ConfigLib.hasVerifierConfigTag(declared, operator.verifiers[i].versionTag)) continue;
      operator.verifiers[i].signatureConfig =
      ConfigLib.verifierConfigByTag(declared, operator.verifiers[i].versionTag).signatureConfig;
    }
  }

  /// @notice THE test seam. Reads every live setting and role for a deployment, one entry
  ///         per recorded verifier.
  /// @dev Typed calls, not raw staticcalls: a missing getter or an undeployed address
  ///      must abort the snapshot rather than silently record `address(0)` as if it
  ///      were the real owner. Writing a zeroed operator file would be worse than failing.
  function snapshot(
    Types.Deployment memory deployment
  ) public view returns (Types.OperatorConfig memory operator) {
    operator.aliasName = deployment.aliasName;

    operator.verifiers = new Types.VerifierConfig[](deployment.verifiers.length);
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      CommitteeVerifier verifier = CommitteeVerifier(deployment.verifiers[i].addr);
      CommitteeVerifier.DynamicConfig memory dynamicConfig = verifier.getDynamicConfig();
      bytes4 finality = verifier.getAllowedFinalityConfig();
      if (FinalityConfigLib.hasReservedBits(finality)) {
        console2.log(
          string.concat(
            "  NOTE verifier ",
            ConfigLib.tagToString(deployment.verifiers[i].versionTag),
            " allowedFinality sets reserved bits; only the two assigned fields are recorded"
          )
        );
      }
      operator.verifiers[i].versionTag = deployment.verifiers[i].versionTag;
      operator.verifiers[i].allowedFinality = FinalityConfigLib.decode(finality);
      operator.verifiers[i].storageLocations = verifier.getStorageLocations();
      operator.verifiers[i].roles = Types.VerifierRoles({
        owner: verifier.owner(),
        storageLocationsAdmin: verifier.getStorageLocationsAdmin(),
        allowlistAdmin: dynamicConfig.allowlistAdmin,
        feeAggregator: dynamicConfig.feeAggregator
      });
    }

    VersionedVerifierResolver resolver = VersionedVerifierResolver(deployment.resolver);
    operator.resolver.roles.owner = resolver.owner();
    operator.resolver.roles.feeAggregator = resolver.getFeeAggregator();

    // Optional: not every chain records a factory (only the CREATE2 bootstrap chain
    // needs one long-term), so an absent factory is a zero, not a failure.
    if (deployment.factory != address(0)) {
      CREATE2Factory factory = CREATE2Factory(deployment.factory);
      operator.factory.roles.owner = factory.owner();
      operator.factory.roles.allowlist = factory.getAllowList();
    }
  }

  /// @notice Serialises a snapshot in the `config/operator/chains` schema.
  /// @dev Assembled by hand: vm.serialize* has no array-of-objects form (same approach as
  ///      `ConfigLib.writeDeploymentByPath`). vm.writeJson re-parses the result, so a
  ///      malformed string fails here rather than at the next load.
  /// @return path The file written.
  function writeSnapshot(
    string memory chainAlias,
    Types.OperatorConfig memory operator
  ) public returns (string memory path) {
    string memory json = string.concat(
      "{\"alias\":",
      _quoted(chainAlias),
      ",\"verifiers\":",
      _verifiersJson(operator.verifiers),
      ",\"resolver\":{\"roles\":{\"owner\":\"",
      vm.toString(operator.resolver.roles.owner),
      "\",\"feeAggregator\":\"",
      vm.toString(operator.resolver.roles.feeAggregator),
      "\"}},\"factory\":{\"roles\":{\"owner\":\"",
      vm.toString(operator.factory.roles.owner),
      "\",\"allowlist\":",
      _addressArrayJson(operator.factory.roles.allowlist),
      "}}}"
    );

    vm.createDir("out/governance", true); // idempotent; survives a fresh clone
    // The block number keeps successive snapshots from clobbering each other.
    path = string.concat("out/governance/", chainAlias, "-", vm.toString(block.number), ".operator.local.json");
    vm.writeJson(json, path);
  }

  function _verifiersJson(
    Types.VerifierConfig[] memory verifiers
  ) private pure returns (string memory json) {
    json = "[";
    for (uint256 i = 0; i < verifiers.length; ++i) {
      string memory settings = string.concat(
        "{\"versionTag\":\"",
        ConfigLib.tagToString(verifiers[i].versionTag),
        "\",\"allowedFinality\":",
        _finalityJson(verifiers[i].allowedFinality),
        ",\"storageLocations\":",
        _stringArrayJson(verifiers[i].storageLocations),
        ",\"signatureConfig\":{\"threshold\":",
        vm.toString(uint256(verifiers[i].signatureConfig.threshold)),
        ",\"signers\":",
        _addressArrayJson(verifiers[i].signatureConfig.signers),
        "}"
      );
      json =
        string.concat(json, i == 0 ? "" : ",", settings, ",\"roles\":", _verifierRolesJson(verifiers[i].roles), "}");
    }
    json = string.concat(json, "]");
  }

  function _verifierRolesJson(
    Types.VerifierRoles memory roles
  ) private pure returns (string memory) {
    return string.concat(
      "{\"owner\":\"",
      vm.toString(roles.owner),
      "\",\"storageLocationsAdmin\":\"",
      vm.toString(roles.storageLocationsAdmin),
      "\",\"allowlistAdmin\":\"",
      vm.toString(roles.allowlistAdmin),
      "\",\"feeAggregator\":\"",
      vm.toString(roles.feeAggregator),
      "\"}"
    );
  }

  /// @dev ConfigLib rejects a literal minBlockDepth of 0, so absent fields are omitted.
  function _finalityJson(
    Types.AllowedFinality memory finality
  ) private pure returns (string memory json) {
    json = "{";
    if (finality.allowSafeTag) json = string.concat(json, "\"allowSafeTag\":true");
    if (finality.minBlockDepth != 0) {
      json = string.concat(
        json, finality.allowSafeTag ? "," : "", "\"minBlockDepth\":", vm.toString(uint256(finality.minBlockDepth))
      );
    }
    json = string.concat(json, "}");
  }

  function _addressArrayJson(
    address[] memory values
  ) private pure returns (string memory json) {
    json = "[";
    for (uint256 i = 0; i < values.length; ++i) {
      json = string.concat(json, i == 0 ? "" : ",", "\"", vm.toString(values[i]), "\"");
    }
    json = string.concat(json, "]");
  }

  function _stringArrayJson(
    string[] memory values
  ) private pure returns (string memory json) {
    json = "[";
    for (uint256 i = 0; i < values.length; ++i) {
      json = string.concat(json, i == 0 ? "" : ",", _quoted(values[i]));
    }
    json = string.concat(json, "]");
  }

  /// @dev JSON string literal; URLs and aliases only need the quote and backslash escapes.
  function _quoted(
    string memory value
  ) private pure returns (string memory) {
    bytes memory b = bytes(value);
    bytes memory out = new bytes(b.length * 2 + 2);
    uint256 n = 0;
    out[n++] = '"';
    for (uint256 i = 0; i < b.length; ++i) {
      if (b[i] == '"' || b[i] == "\\") out[n++] = "\\";
      out[n++] = b[i];
    }
    out[n++] = '"';
    bytes memory trimmed = new bytes(n);
    for (uint256 i = 0; i < n; ++i) {
      trimmed[i] = out[i];
    }
    return string(trimmed);
  }
}
