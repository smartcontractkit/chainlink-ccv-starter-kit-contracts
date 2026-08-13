// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";

/// @title DeployVerifier
/// @notice Outline step 5. Deploys the CommitteeVerifier "normally" (plain CREATE,
///         with constructor args). It is NOT deterministic and its address may
///         differ per chain — that is fine: the verifier rotates behind the stable
///         resolver, so only the resolver needs a fixed address.
///
/// @dev Constructor (grounded against @chainlink/contracts-ccip@2.0.0):
///        constructor(
///          DynamicConfig{address feeAggregator, address allowlistAdmin},
///          string[] storageLocations,   // operator's aggregator endpoint(s)
///          address rmn,                 // MUST be non-zero
///          bytes4 versionTag            // MUST be non-zero, immutable
///        )
///      `storageLocations` may be set now or left empty and updated later via the
///      UpdateStorageLocations script (storageLocationsAdmin role). The deployer
///      becomes the initial storageLocationsAdmin; it is handed over separately.
///
/// Usage:
///   OUTPUT_MODE=EOA forge script script/deploy/DeployVerifier.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
contract DeployVerifier is Script {
  function run(string calldata chainAlias) external returns (address verifier) {
    Types.ChainConfig memory cc = ConfigLib.readChain(chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);

    require(cc.rmn != address(0), "DeployVerifier: rmn must be non-zero");
    require(cc.versionTag != bytes4(0), "DeployVerifier: versionTag must be non-zero");

    CommitteeVerifier.DynamicConfig memory dyn = CommitteeVerifier.DynamicConfig({
      feeAggregator: roles.verifier.feeAggregator,
      allowlistAdmin: roles.verifier.allowlistAdmin
    });

    vm.broadcast();
    CommitteeVerifier v = new CommitteeVerifier(dyn, cc.storageLocations, cc.rmn, cc.versionTag);
    verifier = address(v);

    console2.log("CommitteeVerifier deployed:", verifier);
    console2.log("  versionTag:", vm.toString(cc.versionTag));
    console2.log("  rmn:", cc.rmn);

    // TODO(step 5): record `verifier` into config/deployments/<alias>.json.
    // NEXT: wire the resolver (applyInbound/Outbound implementation updates) and run
    //       the per-lane configure scripts. Owner + storageLocationsAdmin handover
    //       happen last (script/ownership/).
  }
}
