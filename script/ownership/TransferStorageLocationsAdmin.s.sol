// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {console2} from "forge-std/console2.sol";

/// @title TransferStorageLocationsAdmin
/// @notice Outline step 13 (propose leg for the SEPARATE storageLocationsAdmin role).
/// @dev The storageLocationsAdmin is a distinct two-step admin role on the
///      CommitteeVerifier, separate from the contract owner. Current admin proposes;
///      new admin accepts (AcceptStorageLocationsAdmin).
/// @dev Target call: CommitteeVerifier.transferStorageLocationsAdmin(address).
contract TransferStorageLocationsAdmin is BaseScript {
  /// @notice Single source of truth for the transfer-storageLocationsAdmin calldata.
  function callsFor(
    address verifier,
    address proposedAdmin
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({
      to: verifier, value: 0, data: abi.encodeCall(CommitteeVerifier.transferStorageLocationsAdmin, (proposedAdmin))
    });
  }

  function run(
    string calldata chainAlias,
    bytes4 versionTag
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);

    address verifier = ConfigLib.verifierByTag(deployment, versionTag);
    _assertReachable(verifier, "verifier");
    address proposedAdmin =
      ConfigLib.verifierRolesByTag(ConfigLib.readRoles(chainAlias), versionTag).storageLocationsAdmin;
    require(proposedAdmin != address(0), "storageLocationsAdmin role unset");

    console2.log("[TransferStorageLocationsAdmin] versionTag:", ConfigLib.tagToString(versionTag));
    console2.log("  verifier:", verifier);
    console2.log("  storageLocationsAdmin PROPOSED to:", proposedAdmin);
    console2.log("  (must acceptStorageLocationsAdmin() to take effect)");

    _stageMany(callsFor(verifier, proposedAdmin));
    _flush("transfer-storage-locations-admin");
  }
}
