// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Library internals revert in the caller's frame, so expectRevert needs this
///      external-call indirection.
contract LaneDirectionsHarness {
  function requireUniqueDirections(
    Types.LaneConfig[] memory lanes,
    string[] memory paths
  ) external pure {
    ConfigLib.requireUniqueDirections(lanes, paths);
  }
}

/// @notice `ConfigLib.requireUniqueDirections` on in-memory lanes.
contract LaneDirectionsTest is Test {
  bytes4 internal constant TAG = 0x00010001;
  uint64 internal constant SEPOLIA = 16015286601757825753;
  uint64 internal constant BASE_SEPOLIA = 10344971235874465080;
  uint64 internal constant FUJI = 14767482510784806043;

  LaneDirectionsHarness internal harness;

  function setUp() public {
    harness = new LaneDirectionsHarness();
  }

  function _lane(
    string memory name,
    string memory sourceAlias,
    uint64 sourceSelector,
    string memory destAlias,
    uint64 destSelector
  ) internal pure returns (Types.LaneConfig memory lane) {
    lane.name = name;
    lane.source.aliasName = sourceAlias;
    lane.source.chainSelector = sourceSelector;
    lane.dest.aliasName = destAlias;
    lane.dest.chainSelector = destSelector;
    lane.versionTag = TAG;
  }

  function _forward() internal pure returns (Types.LaneConfig memory) {
    return _lane("sepolia-to-base_sepolia", "sepolia", SEPOLIA, "base_sepolia", BASE_SEPOLIA);
  }

  function _pair(
    Types.LaneConfig memory a,
    Types.LaneConfig memory b
  ) internal pure returns (Types.LaneConfig[] memory lanes) {
    lanes = new Types.LaneConfig[](2);
    lanes[0] = a;
    lanes[1] = b;
  }

  string internal constant LANES = "/repo/config/operator/lanes/";

  function _path(
    string memory fileName
  ) internal pure returns (string memory) {
    return string.concat(LANES, fileName, ".json");
  }

  function _check(
    Types.LaneConfig[] memory lanes
  ) internal view {
    string[] memory paths = new string[](lanes.length);
    for (uint256 i = 0; i < lanes.length; ++i) {
      paths[i] = _path(lanes[i].name);
    }
    harness.requireUniqueDirections(lanes, paths);
  }

  function _revertFor(
    string memory a,
    string memory b
  ) internal pure returns (bytes memory) {
    return bytes(
      string.concat(
        "ConfigLib: ", _path(a), " and ", _path(b), " declare the same direction - one file per directed lane"
      )
    );
  }

  function test_acceptsABidirectionalPairAndASecondDestination() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](3);
    lanes[0] = _forward();
    lanes[1] = _lane("base_sepolia-to-sepolia", "base_sepolia", BASE_SEPOLIA, "sepolia", SEPOLIA);
    lanes[2] = _lane("sepolia-to-fuji", "sepolia", SEPOLIA, "fuji", FUJI);
    _check(lanes);
  }

  function test_rejectsTheSameDirectionUnderAnotherTag() public {
    Types.LaneConfig memory copy = _forward();
    copy.name = "sepolia-to-base_sepolia-v2";
    copy.versionTag = 0x00010002;

    vm.expectRevert(_revertFor("sepolia-to-base_sepolia", "sepolia-to-base_sepolia-v2"));
    _check(_pair(_forward(), copy));
  }

  function test_rejectsTheSameSelectorsUnderOtherAliases() public {
    Types.LaneConfig memory copy = _lane("eth_sepolia-to-base", "eth_sepolia", SEPOLIA, "base", BASE_SEPOLIA);

    vm.expectRevert(_revertFor("sepolia-to-base_sepolia", "eth_sepolia-to-base"));
    _check(_pair(_forward(), copy));
  }

  function test_rejectsTheSameAliasesUnderOtherSelectors() public {
    Types.LaneConfig memory copy = _lane("sepolia-to-base_sepolia-typo", "sepolia", 1, "base_sepolia", 2);

    vm.expectRevert(_revertFor("sepolia-to-base_sepolia", "sepolia-to-base_sepolia-typo"));
    _check(_pair(_forward(), copy));
  }

  function test_namesTheFilesWhenACopyKeptTheName() public {
    Types.LaneConfig memory copy = _forward();
    copy.versionTag = 0x00010002;
    string[] memory paths = new string[](2);
    paths[0] = _path("sepolia-to-base_sepolia");
    paths[1] = _path("sepolia-to-base_sepolia-v2");

    vm.expectRevert(_revertFor("sepolia-to-base_sepolia", "sepolia-to-base_sepolia-v2"));
    harness.requireUniqueDirections(_pair(_forward(), copy), paths);
  }
}
