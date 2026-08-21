// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {console2} from "forge-std/console2.sol";

/// @title AcceptStorageLocationsAdmin
/// @notice Called BY the incoming admin to complete the two-step transfer.
/// @dev Target call (grounded): CommitteeVerifier.acceptStorageLocationsAdmin().
contract AcceptStorageLocationsAdmin is BaseScript {
  /// @notice Single source of truth for the accept-storageLocationsAdmin calldata.
  function callsFor(
    address verifier
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({to: verifier, value: 0, data: abi.encodeWithSignature("acceptStorageLocationsAdmin()")});
  }

  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    require(dep.verifier != address(0), "target verifier unset");

    console2.log("[AcceptStorageLocationsAdmin] verifier:", dep.verifier);

    _stageMany(callsFor(dep.verifier));
    _flush("b-accept-storage-locations-admin");
  }
}
