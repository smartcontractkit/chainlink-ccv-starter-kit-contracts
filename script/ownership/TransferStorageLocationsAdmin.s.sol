// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {console2} from "forge-std/console2.sol";

/// @title TransferStorageLocationsAdmin
/// @notice Outline step 13 (propose leg for the SEPARATE storageLocationsAdmin role).
/// @dev The storageLocationsAdmin is a distinct two-step admin role on the
///      CommitteeVerifier, separate from the contract owner. Current admin proposes;
///      new admin accepts (AcceptStorageLocationsAdmin).
/// @dev Target call (grounded): CommitteeVerifier.transferStorageLocationsAdmin(address).
contract TransferStorageLocationsAdmin is BaseScript {
  /// @notice Single source of truth for the transfer-storageLocationsAdmin calldata.
  ///         Reused by Handover.s.sol so any change here propagates to the ceremony.
  function callsFor(
    address verifier,
    address newAdmin
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] =
      Call({to: verifier, value: 0, data: abi.encodeWithSignature("transferStorageLocationsAdmin(address)", newAdmin)});
  }

  function run(
    string calldata chainAlias
  ) external {
    _initOutput();

    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);

    require(dep.verifier != address(0), "target verifier unset");
    require(roles.verifier.storageLocationsAdmin != address(0), "storageLocationsAdmin role unset");

    console2.log("[TransferStorageLocationsAdmin] verifier:", dep.verifier);
    console2.log("  newAdmin:", roles.verifier.storageLocationsAdmin);

    _stageMany(callsFor(dep.verifier, roles.verifier.storageLocationsAdmin));
    _flush("a-transfer-storage-locations-admin");
  }
}
