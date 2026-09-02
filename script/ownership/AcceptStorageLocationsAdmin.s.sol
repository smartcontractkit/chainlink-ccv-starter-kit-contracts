// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {console2} from "forge-std/console2.sol";

/// @title AcceptStorageLocationsAdmin
/// @notice Called BY the incoming admin to complete the two-step transfer.
/// @dev Target call: CommitteeVerifier.acceptStorageLocationsAdmin().
contract AcceptStorageLocationsAdmin is BaseScript {
  /// @notice Single source of truth for the accept-storageLocationsAdmin calldata.
  function callsFor(
    address verifier
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({to: verifier, value: 0, data: abi.encodeCall(CommitteeVerifier.acceptStorageLocationsAdmin, ())});
  }

  function run(
    string calldata chainAlias,
    bytes4 versionTag
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    address verifier = ConfigLib.verifierByTag(deployment, versionTag);
    _assertReachable(verifier, "verifier");

    console2.log("[AcceptStorageLocationsAdmin] versionTag:", ConfigLib.tagToString(versionTag));
    console2.log("  verifier:", verifier);

    _stageMany(callsFor(verifier));
    _flush(string.concat("accept-storage-locations-admin-", ConfigLib.tagToString(versionTag)));
  }
}
