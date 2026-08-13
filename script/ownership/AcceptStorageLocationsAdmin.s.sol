// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";

/// @title AcceptStorageLocationsAdmin
/// @notice Outline step 13 (accept leg for the storageLocationsAdmin role). Called
///         BY the incoming admin to complete the two-step transfer.
/// @dev Target call (grounded): CommitteeVerifier.acceptStorageLocationsAdmin().
contract AcceptStorageLocationsAdmin is BaseScript {
  function run(string calldata chainAlias) external {
    _initOutput();

    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    require(dep.verifier != address(0), "target verifier unset");

    console2.log("[AcceptStorageLocationsAdmin] verifier:", dep.verifier);

    _stage(dep.verifier, abi.encodeWithSignature("acceptStorageLocationsAdmin()"));
    _flush("b-accept-storage-locations-admin");
  }
}
