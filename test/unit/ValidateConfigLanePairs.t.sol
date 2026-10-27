// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ValidateConfig} from "../../script/governance/ValidateConfig.s.sol";
import {Types} from "../../src/lib/Types.sol";
import {Test} from "forge-std/Test.sol";

/// @notice ValidateConfig's cross-lane check, on in-memory lanes through `checkLanePairs`.
/// @dev A fresh script per test: failures accumulate on the instance.
contract ValidateConfigLanePairsTest is Test {
  bytes4 internal constant TAG = 0x00010001;
  bytes4 internal constant TAG_V2 = 0x00010002;
  uint64 internal constant SEPOLIA = 16015286601757825753;
  uint64 internal constant BASE_SEPOLIA = 10344971235874465080;

  ValidateConfig internal validator;

  function setUp() public {
    validator = new ValidateConfig();
  }

  function _lane(
    string memory name,
    string memory sourceAlias,
    uint64 sourceSelector,
    string memory destAlias,
    uint64 destSelector,
    bytes4 tag
  ) internal pure returns (Types.LaneConfig memory lane) {
    lane.name = name;
    lane.source.aliasName = sourceAlias;
    lane.source.chainSelector = sourceSelector;
    lane.dest.aliasName = destAlias;
    lane.dest.chainSelector = destSelector;
    lane.versionTag = tag;
  }

  function _forward() internal pure returns (Types.LaneConfig memory) {
    return _lane("sepolia-to-base_sepolia", "sepolia", SEPOLIA, "base_sepolia", BASE_SEPOLIA, TAG);
  }

  function _pair(
    Types.LaneConfig memory a,
    Types.LaneConfig memory b
  ) internal pure returns (Types.LaneConfig[] memory lanes) {
    lanes = new Types.LaneConfig[](2);
    lanes[0] = a;
    lanes[1] = b;
  }

  function test_acceptsABidirectionalPair() public {
    Types.LaneConfig memory reverse =
      _lane("base_sepolia-to-sepolia", "base_sepolia", BASE_SEPOLIA, "sepolia", SEPOLIA, TAG);
    validator.checkLanePairs(_pair(_forward(), reverse));
  }

  function test_acceptsTwoDestinationsOfOneSource() public {
    Types.LaneConfig memory other = _lane("sepolia-to-fuji", "sepolia", SEPOLIA, "fuji", 14767482510784806043, TAG);
    validator.checkLanePairs(_pair(_forward(), other));
  }

  function test_rejectsTheSameDirectionUnderAnotherTag() public {
    Types.LaneConfig memory copy = _forward();
    copy.name = "sepolia-to-base_sepolia-v2";
    copy.versionTag = TAG_V2;

    vm.expectRevert(abi.encodeWithSelector(ValidateConfig.ValidationFailed.selector, 1));
    validator.checkLanePairs(_pair(_forward(), copy));
  }

  function test_rejectsTheSameSelectorsUnderOtherAliases() public {
    Types.LaneConfig memory copy = _forward();
    copy.name = "eth_sepolia-to-base";
    copy.source.aliasName = "eth_sepolia";
    copy.dest.aliasName = "base";

    vm.expectRevert(abi.encodeWithSelector(ValidateConfig.ValidationFailed.selector, 1));
    validator.checkLanePairs(_pair(_forward(), copy));
  }
}
