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
    BaseScript.Call memory call = script.callFor(address(verifier), _buildAllowlistConfigArgs(enabled, added, removed));
    assertEq(call.to, address(verifier), "target is verifier");
    (ok,) = call.to.call(call.data); // msg.sender == owner (this test)
  }

  function _allowedSenders() internal view returns (address[] memory senders) {
    // the other return values are deliberately ignored
    // forge-lint: disable-next-line(unused-return)
    (, senders) = verifier.getRemoteChainConfig(DEST);
  }

  // ---- isCurrent: what keeps a re-run from restaging applied lanes ----
  // This call is a DELTA, not a full-set replacement, so "current" means the flag
  // matches, every `added` is already present, and no `removed` still is.

  function _lane(
    bool enabled,
    address[] memory added,
    address[] memory removed
  ) internal pure returns (Types.LaneConfig memory lane) {
    lane.name = "test-lane";
    lane.dest.chainSelector = DEST;
    lane.allowlist.allowlistEnabled = enabled;
    lane.allowlist.added = added;
    lane.allowlist.removed = removed;
  }

  function test_isCurrent_falseWhenAddedSenderIsMissing() public view {
    assertFalse(
      script.isCurrent(address(verifier), _lane(true, _single(SENDER_A), new address[](0))), "sender not yet added"
    );
  }

  function test_isCurrent_trueOnceAddedSendersArePresent() public {
    assertTrue(_applyAllowlistUpdate(true, _pair(SENDER_A, SENDER_B), new address[](0)), "apply failed");
    assertTrue(
      script.isCurrent(address(verifier), _lane(true, _pair(SENDER_A, SENDER_B), new address[](0))), "both present"
    );
  }

  function test_isCurrent_falseWhenOnlySomeAddedSendersArePresent() public {
    assertTrue(_applyAllowlistUpdate(true, _single(SENDER_A), new address[](0)), "apply failed");
    assertFalse(
      script.isCurrent(address(verifier), _lane(true, _pair(SENDER_A, SENDER_B), new address[](0))), "B still missing"
    );
  }

  function test_isCurrent_falseWhileARemovedSenderIsStillPresent() public {
    assertTrue(_applyAllowlistUpdate(true, _single(SENDER_A), new address[](0)), "apply failed");
    assertFalse(
      script.isCurrent(address(verifier), _lane(true, new address[](0), _single(SENDER_A))), "removal still pending"
    );
  }

  function test_isCurrent_trueOnceARemovedSenderIsGone() public {
    assertTrue(_applyAllowlistUpdate(true, _single(SENDER_A), new address[](0)), "add failed");
    assertTrue(_applyAllowlistUpdate(true, new address[](0), _single(SENDER_A)), "remove failed");
    assertTrue(
      script.isCurrent(address(verifier), _lane(true, new address[](0), _single(SENDER_A))), "removal already applied"
    );
  }

  function test_isCurrent_falseWhenOnlyTheEnabledFlagDiffers() public {
    assertTrue(_applyAllowlistUpdate(true, _single(SENDER_A), new address[](0)), "apply failed");
    assertFalse(
      script.isCurrent(address(verifier), _lane(false, new address[](0), new address[](0))), "flag flip must stage"
    );
  }

  /// @dev A sender the lane file never mentions is not drift: the delta shape gives this
  ///      script no way to express its removal, so it must not force a pointless restage.
  function test_isCurrent_ignoresSendersTheLaneDoesNotMention() public {
    assertTrue(_applyAllowlistUpdate(true, _pair(SENDER_A, SENDER_B), new address[](0)), "apply failed");
    assertTrue(script.isCurrent(address(verifier), _lane(true, _single(SENDER_A), new address[](0))), "B is not drift");
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

  function test_callFor_enablesAndAddsSenders() public {
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
    BaseScript.Call memory call =
      script.callFor(address(verifier), _buildAllowlistConfigArgs(true, _single(SENDER_A), new address[](0)));
    vm.prank(address(0xBAD));
    (bool ok,) = call.to.call(call.data); // msg.sender == 0xBAD -> OnlyCallableByOwnerOrAllowlistAdmin
    assertFalse(ok, "non-owner/admin should not be able to update allowlist");
  }

  function test_toAllowlistConfigArgs_translatesExampleLane() public view {
    Types.LaneConfig memory lane = ConfigLib.readLaneByPath("config/lanes/sepolia-to-base_sepolia.example.json");
    BaseVerifier.AllowlistConfigArgs memory args = script.toAllowlistConfigArgs(lane);

    assertEq(args.destChainSelector, lane.dest.chainSelector, "dest selector");
    assertEq(args.allowlistEnabled, false, "example lane has allowlist disabled");
    assertEq(args.addedAllowlistedSenders.length, 0, "no adds in example");
    assertEq(args.removedAllowlistedSenders.length, 0, "no removes in example");
  }

  // ---------------------------------------------------------------------------
  //  argsFor: selection, skip and ordering across a lane set
  // ---------------------------------------------------------------------------

  string internal constant SRC_ALIAS = "zz-scratch-src-chain";

  function _selectableLane(
    string memory sourceAlias,
    uint64 destSelector,
    bytes4 tag
  ) internal pure returns (Types.LaneConfig memory lane) {
    // allowlistEnabled=true differs from the verifier's untouched state, so these lanes
    // are selectable AND not already current.
    lane = _lane(true, new address[](0), new address[](0));
    lane.source.aliasName = sourceAlias;
    lane.dest.chainSelector = destSelector;
    lane.versionTag = tag;
  }

  function _oneLane(
    Types.LaneConfig memory lane
  ) internal pure returns (Types.LaneConfig[] memory lanes) {
    lanes = new Types.LaneConfig[](1);
    lanes[0] = lane;
  }

  function test_argsFor_skipsLanesFromAnotherChain() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](2);
    lanes[0] = _selectableLane(SRC_ALIAS, DEST, VERSION_TAG);
    lanes[1] = _selectableLane("zz-scratch-other-chain", 999, VERSION_TAG);

    (BaseVerifier.AllowlistConfigArgs[] memory args, uint256 matched) =
      script.argsFor(lanes, SRC_ALIAS, VERSION_TAG, address(verifier));

    assertEq(matched, 1, "only the lane sourced on this chain matched");
    assertEq(args.length, 1);
    assertEq(args[0].destChainSelector, DEST);
  }

  function test_argsFor_skipsLanesPinnedToAnotherTag() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](2);
    lanes[0] = _selectableLane(SRC_ALIAS, DEST, VERSION_TAG);
    lanes[1] = _selectableLane(SRC_ALIAS, 999, VERSION_TAG_V2);

    (BaseVerifier.AllowlistConfigArgs[] memory args, uint256 matched) =
      script.argsFor(lanes, SRC_ALIAS, VERSION_TAG, address(verifier));

    assertEq(matched, 1, "the other tag is a different verifier's business");
    assertEq(args.length, 1);
  }

  /// @dev The array length IS the staged count: the over-allocated tail must not survive.
  function test_argsFor_lengthIsTheStagedCount() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](4);
    lanes[0] = _selectableLane(SRC_ALIAS, 111, VERSION_TAG);
    lanes[1] = _selectableLane("zz-scratch-other-chain", 222, VERSION_TAG);
    lanes[2] = _selectableLane(SRC_ALIAS, 333, VERSION_TAG);
    lanes[3] = _selectableLane(SRC_ALIAS, 444, VERSION_TAG_V2);

    (BaseVerifier.AllowlistConfigArgs[] memory args, uint256 matched) =
      script.argsFor(lanes, SRC_ALIAS, VERSION_TAG, address(verifier));

    assertEq(matched, 2, "two lanes matched the filters");
    assertEq(args.length, 2, "trimmed from the 4-slot upper bound");
    assertEq(args[0].destChainSelector, 111, "lane order preserved");
    assertEq(args[1].destChainSelector, 333, "lane order preserved");
  }

  /// @dev A lane already applied on-chain counts as matched but must not be staged.
  function test_argsFor_skipsLaneAlreadyCurrentButStillCountsIt() public view {
    // allowlistEnabled=false with no adds/removes is the verifier's untouched state.
    Types.LaneConfig memory lane = _selectableLane(SRC_ALIAS, DEST, VERSION_TAG);
    lane.allowlist.allowlistEnabled = false;
    assertTrue(script.isCurrent(address(verifier), lane), "setup: already current");

    (BaseVerifier.AllowlistConfigArgs[] memory args, uint256 matched) =
      script.argsFor(_oneLane(lane), SRC_ALIAS, VERSION_TAG, address(verifier));

    assertEq(matched, 1, "the lane still matched the filters");
    assertEq(args.length, 0, "but nothing to stage");
  }

  /// @dev The point of batching: two matched lanes become ONE call that applies both.
  function test_batchedCall_appliesEveryMatchedLaneInOneCall() public {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](2);
    lanes[0] = _selectableLane(SRC_ALIAS, 111, VERSION_TAG);
    lanes[1] = _selectableLane(SRC_ALIAS, 222, VERSION_TAG);

    (BaseVerifier.AllowlistConfigArgs[] memory args, uint256 matched) =
      script.argsFor(lanes, SRC_ALIAS, VERSION_TAG, address(verifier));
    assertEq(matched, 2);
    assertEq(args.length, 2, "both lanes staged");

    BaseScript.Call memory call = script.callFor(address(verifier), args);
    (bool ok,) = call.to.call(call.data);
    assertTrue(ok, "the single batched call applied");

    assertTrue(script.isCurrent(address(verifier), lanes[0]), "dest 111 configured");
    assertTrue(script.isCurrent(address(verifier), lanes[1]), "dest 222 configured");
  }
}
