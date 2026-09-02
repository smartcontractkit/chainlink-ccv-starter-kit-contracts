// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployVerifier
/// @notice Deploys the CommitteeVerifier (plain CREATE, with constructor
///         args) and hands the owner + storageLocationsAdmin roles to their CONFIGURED
///         holders (config/roles/<alias>.json). It is NOT deterministic and its address
///         may differ per chain: fine, it rotates behind the stable resolver.
///
/// @dev Role handover rule (each role independently):
///        - configured holder == deployer: keep it (the deployer owns/admins it and can
///          run the config scripts directly — EOA / testing path).
///        - configured holder is another EOA / a Safe: PROPOSE the 2-step transfer; that
///          holder accepts before configuring (script/ownership/AcceptOwnership /
///          AcceptStorageLocationsAdmin, or the b- handover batch).
///
/// @dev feeAggregator + allowlistAdmin come from roles and can be re-pointed later via
///      SetDynamicConfig; storageLocations via UpdateStorageLocations.
///
/// @dev The versionTag is an explicit argument: each deploy creates a
///      new verifier, appended to `verifiers` in the deployment record. A duplicate tag
///      reverts; ALLOW_TAG_REPLACE=true replaces that entry instead, for redoing a deploy
///      that went wrong before anything referenced it (never while it carries traffic).
///
/// Usage:
///   OUTPUT_MODE=EOA forge script script/deploy/DeployVerifier.s.sol \
///     --sig "run(string,bytes4)" sepolia 0x00010001 --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
contract DeployVerifier is Script {
  function run(
    string calldata chainAlias,
    bytes4 versionTag
  ) external returns (address verifier) {
    // Validate the tag before any tag-keyed lookup, so a bad argument fails on
    // itself rather than inside a config read.
    require(versionTag != bytes4(0), "DeployVerifier: versionTag must be non-zero");
    // The repo-wide catalog is the spelling authority for tags (they must match across
    // chains); an uncataloged tag is a typo or an undeclared verifier.
    ConfigLib.requireKnownTag(versionTag, "deploy argument");

    Types.ChainConfig memory chainConfig = ConfigLib.readChain(chainAlias);
    ConfigLib.assertChainMatches(chainConfig, chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeploymentOrEmpty(chainAlias);
    // Roles are per verifier and precede the deploy: reverts unless
    // config/roles/<alias>.json declares a verifiers entry for this tag.
    Types.VerifierRoles memory verifierRoles = ConfigLib.verifierRolesByTag(roles, versionTag);

    require(chainConfig.rmn != address(0), "DeployVerifier: rmn must be non-zero");
    require(verifierRoles.owner != address(0), "DeployVerifier: verifier.owner role unset");
    require(
      verifierRoles.storageLocationsAdmin != address(0), "DeployVerifier: verifier.storageLocationsAdmin role unset"
    );
    require(verifierRoles.feeAggregator != address(0), "DeployVerifier: verifier.feeAggregator role unset");

    address deployer = msg.sender;

    CommitteeVerifier.DynamicConfig memory dynamicConfig = CommitteeVerifier.DynamicConfig({
      feeAggregator: verifierRoles.feeAggregator, allowlistAdmin: verifierRoles.allowlistAdmin
    });

    vm.broadcast();
    CommitteeVerifier v =
      new CommitteeVerifier(dynamicConfig, chainConfig.storageLocations, chainConfig.rmn, versionTag);
    verifier = address(v);

    console2.log("[DeployVerifier] chain:", chainAlias);
    console2.log("  verifier deployed:", verifier);
    console2.log("  versionTag:", ConfigLib.tagToString(versionTag));
    console2.log("  rmn:", chainConfig.rmn);

    // ---- owner handover ----
    if (verifierRoles.owner == deployer) {
      console2.log("  owner: deployer (configured verifier.owner == deployer)");
    } else {
      vm.broadcast();
      v.transferOwnership(verifierRoles.owner);
      console2.log("  owner PROPOSED to:", verifierRoles.owner);
      console2.log("  (must acceptOwnership() before running owner-gated config scripts)");
    }

    // ---- storageLocationsAdmin handover ----
    if (verifierRoles.storageLocationsAdmin == deployer) {
      console2.log("  storageLocationsAdmin: deployer");
    } else {
      vm.broadcast();
      v.transferStorageLocationsAdmin(verifierRoles.storageLocationsAdmin);
      console2.log("  storageLocationsAdmin PROPOSED to:", verifierRoles.storageLocationsAdmin);
      console2.log("  (must acceptStorageLocationsAdmin() before running UpdateStorageLocations)");
    }

    _recordVerifier(deployment, versionTag, verifier, vm.envOr("ALLOW_TAG_REPLACE", false));
    ConfigLib.writeDeployment(deployment);
    console2.log("  recorded ->", ConfigLib.deploymentPath(chainAlias));
  }

  /// @dev Appends the new verifier; a tag already on record means this run would
  ///      silently orphan the previous deploy, so it reverts unless explicitly waived.
  function _recordVerifier(
    Types.Deployment memory deployment,
    bytes4 versionTag,
    address verifier,
    bool allowReplace
  ) internal pure {
    if (ConfigLib.hasVerifierTag(deployment, versionTag)) {
      require(
        allowReplace,
        string.concat(
          "DeployVerifier: versionTag ",
          ConfigLib.tagToString(versionTag),
          " already recorded for ",
          deployment.aliasName,
          " - pick a new tag, or set ALLOW_TAG_REPLACE=true to replace a deploy nothing references yet"
        )
      );
      console2.log("  WARN replacing recorded verifier for tag (ALLOW_TAG_REPLACE):", ConfigLib.tagToString(versionTag));
      console2.log(
        "  WARN previous address is dropped from the record:", ConfigLib.verifierByTag(deployment, versionTag)
      );
      for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
        if (deployment.verifiers[i].versionTag == versionTag) deployment.verifiers[i].addr = verifier;
      }
      return;
    }

    Types.VerifierDeployment[] memory extended = new Types.VerifierDeployment[](deployment.verifiers.length + 1);
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      extended[i] = deployment.verifiers[i];
    }
    extended[deployment.verifiers.length] = Types.VerifierDeployment({versionTag: versionTag, addr: verifier});
    deployment.verifiers = extended;
  }
}
