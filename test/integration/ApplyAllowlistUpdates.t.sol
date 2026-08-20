// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ApplyAllowlistUpdates} from "../../script/configure/ApplyAllowlistUpdates.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";

/// @notice Exercises the ApplyAllowlistUpdates builder against the real audited
///         CommitteeVerifier (deployed by the fixture; this test is owner + allowlistAdmin).
contract ApplyAllowlistUpdatesTest is CommitteeVerifierSetup {
  ApplyAllowlistUpdates internal script;

  uint64 internal constant DEST = 14767482510784806043; // Fuji selector
  address internal constant SENDER_A = address(0xA1);
  address internal constant SENDER_B = address(0xA2);

  function setUp() public override {
    super.setUp();
    script = new ApplyAllowlistUpdates();
  }

  function _buildAllowlistConfigArgs(
    bool enabled,
    address[] memory added,
    address[] memory removed
  ) internal pure returns (BaseVerifier.AllowlistConfigArgs[] memory args) {
    args = new BaseVerifier.AllowlistConfigArgs[](1);
    args[0] = BaseVerifier.AllowlistConfigArgs({
      destChainSelector: DEST,
      allowlistEnabled: enabled,
      addedAllowlistedSenders: added,
      removedAllowlistedSenders: removed
    });
  }

  function _applyAllowlistUpdate(
    bool enabled,
    address[] memory added,
    address[] memory removed
  ) internal returns (bool ok) {
    BaseScript.Call[] memory calls =
      script.callsFor(address(verifier), _buildAllowlistConfigArgs(enabled, added, removed));
    assertEq(calls.length, 1, "one call expected");
    assertEq(calls[0].to, address(verifier), "target is verifier");
    (ok,) = calls[0].to.call(calls[0].data); // msg.sender == owner (this test)
  }

  function _allowedSenders() internal view returns (address[] memory senders) {
    (, senders) = verifier.getRemoteChainConfig(DEST);
  }

  function _pair(
    address a,
    address b
  ) internal pure returns (address[] memory arr) {
    arr = new address[](2);
    arr[0] = a;
    arr[1] = b;
  }

  function _single(
    address a
  ) internal pure returns (address[] memory arr) {
    arr = new address[](1);
    arr[0] = a;
  }

  function test_callsFor_enablesAndAddsSenders() public {
    assertTrue(_applyAllowlistUpdate(true, _pair(SENDER_A, SENDER_B), new address[](0)), "apply failed");

    (BaseVerifier.RemoteChainConfigArgs memory cfg, address[] memory senders) = verifier.getRemoteChainConfig(DEST);
    assertTrue(cfg.allowlistEnabled, "allowlist should be enabled");
    assertEq(senders.length, 2, "two senders allowed");
  }

  function test_removeSender_leavesRemainder() public {
    assertTrue(_applyAllowlistUpdate(true, _pair(SENDER_A, SENDER_B), new address[](0)), "add failed");
    assertTrue(_applyAllowlistUpdate(true, new address[](0), _single(SENDER_A)), "remove failed");

    address[] memory senders = _allowedSenders();
    assertEq(senders.length, 1, "one sender remains");
    assertEq(senders[0], SENDER_B, "remaining sender is B");
  }

  function test_reverts_whenAddingWithAllowlistDisabled() public {
    // Contract reverts InvalidAllowListRequest (adds require allowlistEnabled == true).
    assertFalse(_applyAllowlistUpdate(false, _single(SENDER_A), new address[](0)), "should have reverted");
  }

  function test_reverts_whenCallerNotOwnerNorAllowlistAdmin() public {
    BaseScript.Call[] memory calls =
      script.callsFor(address(verifier), _buildAllowlistConfigArgs(true, _single(SENDER_A), new address[](0)));
    vm.prank(address(0xBAD));
    (bool ok,) = calls[0].to.call(calls[0].data); // msg.sender == 0xBAD -> OnlyCallableByOwnerOrAllowlistAdmin
    assertFalse(ok, "non-owner/admin should not be able to update allowlist");
  }

  function test_toAllowlistConfigArgs_translatesExampleLane() public view {
    Types.LaneConfig memory lane = ConfigLib.readLaneByPath("config/lanes/sepolia-to-base_sepolia.example.json");
    BaseVerifier.AllowlistConfigArgs[] memory args = script.toAllowlistConfigArgs(lane);

    assertEq(args.length, 1);
    assertEq(args[0].destChainSelector, lane.dest.chainSelector, "dest selector");
    assertEq(args[0].allowlistEnabled, false, "example lane has allowlist disabled");
    assertEq(args[0].addedAllowlistedSenders.length, 0, "no adds in example");
    assertEq(args[0].removedAllowlistedSenders.length, 0, "no removes in example");
  }
}
