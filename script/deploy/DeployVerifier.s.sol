// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";

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
  function run(string calldata chainAlias) external returns (address verifier) {
    Types.ChainConfig memory cc = ConfigLib.readChain(chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);
    Types.Deployment memory dep = ConfigLib.readDeploymentOrEmpty(chainAlias);

    require(cc.rmn != address(0), "DeployVerifier: rmn must be non-zero");
    require(cc.versionTag != bytes4(0), "DeployVerifier: versionTag must be non-zero");
    require(roles.verifier.owner != address(0), "DeployVerifier: verifier.owner role unset");
    require(roles.verifier.storageLocationsAdmin != address(0), "DeployVerifier: verifier.storageLocationsAdmin role unset");

    address deployer = msg.sender;

    CommitteeVerifier.DynamicConfig memory dyn = CommitteeVerifier.DynamicConfig({
      feeAggregator: roles.verifier.feeAggregator,
      allowlistAdmin: roles.verifier.allowlistAdmin
    });

    vm.broadcast();
    CommitteeVerifier v = new CommitteeVerifier(dyn, cc.storageLocations, cc.rmn, cc.versionTag);
    verifier = address(v);

    console2.log("[DeployVerifier] chain:", chainAlias);
    console2.log("  verifier deployed:", verifier);
    console2.log("  versionTag:", vm.toString(cc.versionTag));
    console2.log("  rmn:", cc.rmn);

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

    if (roles.verifier.feeAggregator == address(0)) {
      console2.log("  WARN verifier feeAggregator is zero: fee withdrawals will revert until set");
    }

    dep.verifier = verifier;
    ConfigLib.writeDeployment(dep);
    console2.log("  recorded ->", ConfigLib.deploymentPath(chainAlias));
  }
}