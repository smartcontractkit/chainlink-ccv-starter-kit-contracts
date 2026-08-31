// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {console2} from "forge-std/console2.sol";

/// @title CancelStorageLocationsAdmin
/// @notice Cancels a pending storageLocationsAdmin transfer on the CommitteeVerifier by
///         re-proposing address(0): the contract keeps exactly one pending admin, so
///         overwriting it with zero leaves nobody able to accept.
/// @dev Executed by the CURRENT admin (gated on-chain); the zero address lives only here
///      so TransferStorageLocationsAdmin keeps rejecting it as a proposed admin.
/// @dev Harmless when nothing is pending: the call just overwrites zero with zero.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/ownership/CancelStorageLocationsAdmin.s.sol \
///     --sig "run(string)" sepolia
contract CancelStorageLocationsAdmin is BaseScript {
  function callsFor(
    address verifier
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({
      to: verifier, value: 0, data: abi.encodeCall(CommitteeVerifier.transferStorageLocationsAdmin, (address(0)))
    });
  }

  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    require(deployment.verifier != address(0), "CancelStorageLocationsAdmin: verifier unset");

    console2.log("[CancelStorageLocationsAdmin] verifier:", deployment.verifier);
    console2.log("  clearing any pending storageLocationsAdmin (re-proposing address(0))");

    _stageMany(callsFor(deployment.verifier));
    _flush("cancel-storage-locations-admin");
  }
}
