// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";

/// @notice Unit tests for the config-as-data loader. Uses the shipped example files
///         directly (path-based) so it does not depend on operator-specific configs.
contract ConfigLibTest is Test {
  string internal constant LANE_EXAMPLE = "config/lanes/sepolia-to-base_sepolia.example.json";

  function test_readLaneByPath_parsesExample() public view {
    Types.LaneConfig memory lane = ConfigLib.readLaneByPath(LANE_EXAMPLE);

    assertEq(lane.name, "sepolia-to-base_sepolia");
    assertEq(lane.source.aliasName, "sepolia");
    assertEq(lane.source.chainSelector, 16015286601757825753);
    assertEq(lane.dest.aliasName, "base_sepolia");
    assertEq(lane.dest.chainSelector, 10344971235874465080);

    // Signature config must respect the "not 1-of-1, threshold > 2/3" constraint.
    assertEq(lane.sig.threshold, 7);
    assertEq(lane.sig.signers.length, 10);
    assertGt(lane.sig.threshold, 1); // not 1-of-1
    assertGt(uint256(lane.sig.threshold) * 3, lane.sig.signers.length * 2); // > 2/3
  }

  function test_listLanes_skipsTemplatesAndExamples() public view {
    // Only real (non-_template, non-.example) files should be listed.
    string[] memory lanes = ConfigLib.listLanes();
    for (uint256 i; i < lanes.length; ++i) {
      assertEq(_endsWithJson(lanes[i]), true);
    }
    // With only example/template files present, expect zero real lanes.
    assertEq(lanes.length, 0);
  }

  // TODO: once real config/chains/<alias>.json and config/roles/<alias>.json exist,
  //       add readChain / readRoles round-trip tests here. (readChain/readRoles are
  //       alias-based; point them at your real deployment aliases.)

  function _endsWithJson(string memory s) private pure returns (bool) {
    bytes memory b = bytes(s);
    if (b.length < 5) return false;
    return b[b.length - 5] == "." && b[b.length - 4] == "j" && b[b.length - 3] == "s"
      && b[b.length - 2] == "o" && b[b.length - 1] == "n";
  }
}
