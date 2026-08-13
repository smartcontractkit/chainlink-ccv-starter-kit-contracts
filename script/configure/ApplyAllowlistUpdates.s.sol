// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";

/// @title ApplyAllowlistUpdates
/// @notice Outline step 8. Sender allowlist per destination.
/// @dev Target call (grounded):
///        CommitteeVerifier.applyAllowlistUpdates(AllowlistConfigArgs[])
///        AllowlistConfigArgs = {
///          uint64 destChainSelector; bool allowlistEnabled;
///          address[] addedAllowlistedSenders; address[] removedAllowlistedSenders;
///        }
/// @dev Caller may be the owner OR the DynamicConfig.allowlistAdmin (contract allows both).
contract ApplyAllowlistUpdates is BaseScript {
  bytes4 internal constant SELECTOR = CommitteeVerifier.applyAllowlistUpdates.selector;

  function run() external {
    _initOutput();

    string[] memory lanes = ConfigLib.listLanes();
    for (uint256 i; i < lanes.length; ++i) {
      Types.LaneConfig memory lane = ConfigLib.readLaneByPath(lanes[i]);
      Types.Deployment memory dep = ConfigLib.readDeployment(lane.source.aliasName);

      console2.log("[ApplyAllowlistUpdates] lane:", lane.name);
      console2.log("  target verifier (source):", dep.verifier);

      // TODO(step 8): build CommitteeVerifier.AllowlistConfigArgs[] from lane.allowlist
      //   (destChainSelector = lane.dest.chainSelector), then:
      //   _stage(dep.verifier, abi.encodeCall(CommitteeVerifier.applyAllowlistUpdates, (args)));
    }

    _flush("c-apply-allowlist-updates");
  }
}
