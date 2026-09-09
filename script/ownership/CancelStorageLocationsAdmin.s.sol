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
/// @dev Preflight reads chain state, so --rpc-url is required even in SAFE mode. In SAFE
///      mode the batch is refused unless SAFE_ADDRESS is the current on-chain admin; EOA
///      runs get the same guarantee from forge's pre-broadcast simulation reverting.
///
/// Usage (versionTag selects which recorded verifier):
///   OUTPUT_MODE=SAFE forge script script/ownership/CancelStorageLocationsAdmin.s.sol \
///     --sig "run(string,bytes4)" sepolia 0x00010001
contract CancelStorageLocationsAdmin is BaseScript {
  function callFor(
    address verifier
  ) public pure returns (Call memory call) {
    call = Call({
      to: verifier, value: 0, data: abi.encodeCall(CommitteeVerifier.transferStorageLocationsAdmin, (address(0)))
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
    // SAFE-only: EOA runs execute now, so forge's pre-broadcast simulation already
    // reverts on a non-admin sender. Only a deferred batch can hide the mismatch.
    if (outputMode == OutputMode.SAFE) requireExecutorIsCurrentAdmin(verifier, outputSafeAddress);

    console2.log("[CancelStorageLocationsAdmin] versionTag:", ConfigLib.tagToString(versionTag));
    console2.log("  verifier:", verifier);
    console2.log("  clearing any pending storageLocationsAdmin (re-proposing address(0))");

    _stage(callFor(verifier));
    _flush(string.concat("cancel-storage-locations-admin-", ConfigLib.tagToString(versionTag)));
  }

  /// @notice Reverts unless expectedExecutor is the verifier's current storageLocationsAdmin.
  /// @dev Thin wrapper: only the role getter is CommitteeVerifier-specific, the
  ///      assertion itself is BaseScript's.
  function requireExecutorIsCurrentAdmin(
    address verifier,
    address expectedExecutor
  ) public view {
    _requireExecutorHoldsRole(
      verifier,
      expectedExecutor,
      CommitteeVerifier(verifier).getStorageLocationsAdmin(),
      "current storageLocationsAdmin"
    );
  }
}
