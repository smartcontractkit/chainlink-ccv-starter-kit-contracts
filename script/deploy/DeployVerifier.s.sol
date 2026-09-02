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
/// Usage:
///   OUTPUT_MODE=EOA forge script script/deploy/DeployVerifier.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
contract DeployVerifier is Script {
  function run(
    string calldata chainAlias
  ) external returns (address verifier) {
    // A wrong-chain deploy succeeds cleanly and pollutes the deployment record, so verify first.
    Types.ChainConfig memory chainConfig = ConfigLib.readChain(chainAlias);
    ConfigLib.assertChainMatches(chainConfig, chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeploymentOrEmpty(chainAlias);

    require(chainConfig.rmn != address(0), "DeployVerifier: rmn must be non-zero");
    require(chainConfig.versionTag != bytes4(0), "DeployVerifier: versionTag must be non-zero");
    require(roles.verifier.owner != address(0), "DeployVerifier: verifier.owner role unset");
    require(
      roles.verifier.storageLocationsAdmin != address(0), "DeployVerifier: verifier.storageLocationsAdmin role unset"
    );
    require(roles.verifier.feeAggregator != address(0), "DeployVerifier: verifier.feeAggregator role unset");

    address deployer = msg.sender;

    CommitteeVerifier.DynamicConfig memory dynamicConfig = CommitteeVerifier.DynamicConfig({
      feeAggregator: roles.verifier.feeAggregator, allowlistAdmin: roles.verifier.allowlistAdmin
    });

    vm.broadcast();
    CommitteeVerifier v =
      new CommitteeVerifier(dynamicConfig, chainConfig.storageLocations, chainConfig.rmn, chainConfig.versionTag);
    verifier = address(v);

    console2.log("[DeployVerifier] chain:", chainAlias);
    console2.log("  verifier deployed:", verifier);
    console2.log("  versionTag:", vm.toString(chainConfig.versionTag));
    console2.log("  rmn:", chainConfig.rmn);

    // ---- owner handover ----
    if (roles.verifier.owner == deployer) {
      console2.log("  owner: deployer (configured verifier.owner == deployer)");
    } else {
      vm.broadcast();
      v.transferOwnership(roles.verifier.owner);
      console2.log("  owner PROPOSED to:", roles.verifier.owner);
      console2.log("  (must acceptOwnership() before running owner-gated config scripts)");
    }

    // ---- storageLocationsAdmin handover ----
    if (roles.verifier.storageLocationsAdmin == deployer) {
      console2.log("  storageLocationsAdmin: deployer");
    } else {
      vm.broadcast();
      v.transferStorageLocationsAdmin(roles.verifier.storageLocationsAdmin);
      console2.log("  storageLocationsAdmin PROPOSED to:", roles.verifier.storageLocationsAdmin);
      console2.log("  (must acceptStorageLocationsAdmin() before running UpdateStorageLocations)");
    }

    deployment.verifier = verifier;
    ConfigLib.writeDeployment(deployment);
    console2.log("  recorded ->", ConfigLib.deploymentPath(chainAlias));
  }
}
