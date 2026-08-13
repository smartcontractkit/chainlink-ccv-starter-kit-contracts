// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";

/// @title ApplyOutboundImplementationUpdates
/// @notice Outline step 11 (resolver, per destination). Points each destination
///         chain selector at the verifier that handles its OUTBOUND traffic.
/// @dev Target call (grounded):
///        VersionedVerifierResolver.applyOutboundImplementationUpdates(OutboundImplementationArgs[])
///        OutboundImplementationArgs = { uint64 destChainSelector; address verifier }
///      Set at deploy time; also the upgrade path for rotating a verifier behind
///      the stable resolver. A zero verifier clears the mapping for that dest.
contract ApplyOutboundImplementationUpdates is BaseScript {
  bytes4 internal constant SELECTOR = VersionedVerifierResolver.applyOutboundImplementationUpdates.selector;

  function run(string calldata chainAlias) external {
    _initOutput();

    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    console2.log("[ApplyOutboundImplementationUpdates] chain:", chainAlias);
    console2.log("  target resolver:", dep.resolver);
    console2.log("  local verifier:", dep.verifier);

    string[] memory lanes = ConfigLib.listLanes();
    for (uint256 i; i < lanes.length; ++i) {
      Types.LaneConfig memory lane = ConfigLib.readLaneByPath(lanes[i]);
      if (!_eq(lane.source.aliasName, chainAlias)) continue; // outbound lanes from this chain
      console2.log("  outbound dest selector for lane:", lane.name);
      // TODO(step 11): accumulate OutboundImplementationArgs{destChainSelector: lane.dest.chainSelector,
      //   verifier: dep.verifier} for each outbound lane, then stage ONE batched call:
      //   _stage(dep.resolver, abi.encodeCall(
      //     VersionedVerifierResolver.applyOutboundImplementationUpdates, (args)));
    }

    _flush("apply-outbound-implementations");
  }
}
