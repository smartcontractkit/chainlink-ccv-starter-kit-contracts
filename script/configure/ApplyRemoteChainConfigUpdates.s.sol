// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";

/// @title ApplyRemoteChainConfigUpdates
/// @notice Outline step 7. Per destination: router + verification fee + gas + payload size.
/// @dev Target call (grounded):
///        CommitteeVerifier.applyRemoteChainConfigUpdates(RemoteChainConfigArgs[])
///        RemoteChainConfigArgs = {
///          IRouter router; uint64 remoteChainSelector; bool allowlistEnabled;
///          uint16 feeUSDCents; uint32 gasForVerification; uint16 payloadSizeBytes;
///        }
///
/// @dev EMERGENCY LEVER: setting router == address(0) for a destination is the ONLY
///      outbound pause. There is no inbound halt — document this asymmetry so an
///      operator under incident does not hunt for a switch that does not exist.
///
/// @dev DIRECTION (confirm vs Chainlink Go sequence): applied on the SOURCE chain's
///      verifier, keyed by the DEST (remote) chain selector.
contract ApplyRemoteChainConfigUpdates is BaseScript {
  bytes4 internal constant SELECTOR = CommitteeVerifier.applyRemoteChainConfigUpdates.selector;

  function run() external {
    _initOutput();

    string[] memory lanes = ConfigLib.listLanes();
    for (uint256 i; i < lanes.length; ++i) {
      Types.LaneConfig memory lane = ConfigLib.readLaneByPath(lanes[i]);
      Types.Deployment memory dep = ConfigLib.readDeployment(lane.source.aliasName);

      console2.log("[ApplyRemoteChainConfigUpdates] lane:", lane.name);
      console2.log("  target verifier (source):", dep.verifier);
      console2.log("  router:", lane.remote.router);

      // TODO(step 7): build CommitteeVerifier.RemoteChainConfigArgs[] from lane.remote
      //   (remoteChainSelector = lane.dest.chainSelector; router wrapped as IRouter),
      //   then: _stage(dep.verifier, abi.encodeCall(CommitteeVerifier.applyRemoteChainConfigUpdates, (args)));
    }

    _flush("b-apply-remote-chain-config");
  }
}
