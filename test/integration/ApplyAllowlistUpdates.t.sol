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

  /// @dev One entry for DEST: the script's delta from the current on-chain set to `senders`.
  function _argsFor(
    bool enabled,
    address[] memory senders
  ) internal view returns (BaseVerifier.AllowlistConfigArgs[] memory args) {
    args = new BaseVerifier.AllowlistConfigArgs[](1);
    args[0] = script.toAllowlistConfigArgs(_lane(enabled, senders), _allowedSenders());
  }

  /// @dev Applies the desired set through the script's own builders.
  function _apply(
    bool enabled,
    address[] memory senders
  ) internal returns (bool ok) {
    BaseScript.Call memory call = script.callFor(address(verifier), _argsFor(enabled, senders));
    assertEq(call.to, address(verifier), "target is verifier");
    (ok,) = call.to.call(call.data); // msg.sender == owner (this test)
  }

  function _allowedSenders() internal view returns (address[] memory senders) {
    // the other return values are deliberately ignored
    // forge-lint: disable-next-line(unused-return)
    (, senders) = verifier.getRemoteChainConfig(DEST);
  }

  function _lane(
    bool enabled,
    address[] memory allowedSenders
  ) internal pure returns (Types.LaneConfig memory lane) {
    lane.name = "test-lane";
    lane.dest.chainSelector = DEST;
    lane.allowlist.allowlistEnabled = enabled;
    lane.allowlist.allowedSenders = allowedSenders;
  }

  function _none() internal pure returns (address[] memory arr) {
    arr = new address[](0);
  }

  function _single(
    address a
  ) internal pure returns (address[] memory arr) {
    arr = new address[](1);
    arr[0] = a;
  }

  function _pair(
    address a,
    address b
  ) internal pure returns (address[] memory arr) {
    arr = new address[](2);
    arr[0] = a;
    arr[1] = b;
  }

  // ---- isCurrent: what keeps a re-run from restaging applied lanes ----
  // `allowedSenders` is the desired FULL set, so "current" means the flag matches and the
  // on-chain set equals it exactly, order ignored.

  function test_isCurrent_falseWhenADesiredSenderIsMissing() public view {
    assertFalse(script.isCurrent(address(verifier), _lane(true, _single(SENDER_A))), "sender not yet added");
  }

  function test_isCurrent_trueOnceTheSetMatches() public {
    assertTrue(_apply(true, _pair(SENDER_A, SENDER_B)), "apply failed");
    assertTrue(script.isCurrent(address(verifier), _lane(true, _pair(SENDER_A, SENDER_B))), "both present");
  }

  function test_isCurrent_falseWhenOnlySomeDesiredSendersArePresent() public {
    assertTrue(_apply(true, _single(SENDER_A)), "apply failed");
    assertFalse(script.isCurrent(address(verifier), _lane(true, _pair(SENDER_A, SENDER_B))), "B still missing");
  }

  /// @dev The point of the desired-set shape: a sender on-chain that the lane file does
  ///      not list IS a difference, and the reconciler removes it.
  function test_isCurrent_falseWhenAnUndeclaredSenderIsOnChain() public {
    assertTrue(_apply(true, _pair(SENDER_A, SENDER_B)), "apply failed");
    assertFalse(script.isCurrent(address(verifier), _lane(true, _single(SENDER_A))), "B is not in config");
  }

  function test_isCurrent_ignoresSenderOrder() public {
    assertTrue(_apply(true, _pair(SENDER_A, SENDER_B)), "apply failed");
    assertTrue(script.isCurrent(address(verifier), _lane(true, _pair(SENDER_B, SENDER_A))), "same set");
  }

  function test_isCurrent_falseWhenOnlyTheEnabledFlagDiffers() public {
    assertTrue(_apply(true, _none()), "apply failed");
    assertFalse(script.isCurrent(address(verifier), _lane(false, _none())), "flag flip must stage");
  }

  // ---- toAllowlistConfigArgs: the delta against a given on-chain set ----

  function test_toAllowlistConfigArgs_stagesOnlyTheDelta() public view {
    BaseVerifier.AllowlistConfigArgs memory args =
      script.toAllowlistConfigArgs(_lane(true, _pair(SENDER_A, SENDER_B)), _pair(SENDER_B, address(0xA3)));

    assertEq(args.destChainSelector, DEST, "dest selector");
    assertTrue(args.allowlistEnabled, "flag carried through");
    assertEq(args.addedAllowlistedSenders.length, 1, "one add");
    assertEq(args.addedAllowlistedSenders[0], SENDER_A, "A is desired but absent");
    assertEq(args.removedAllowlistedSenders.length, 1, "one remove");
    assertEq(args.removedAllowlistedSenders[0], address(0xA3), "0xA3 is present but not desired");
  }

  function test_toAllowlistConfigArgs_translatesExampleLane() public view {
    Types.LaneConfig memory lane =
      ConfigLib.readLaneByPath("config/operator/lanes/sepolia-to-base_sepolia.example.json");
    BaseVerifier.AllowlistConfigArgs memory args = script.toAllowlistConfigArgs(lane, _none());

    assertEq(args.destChainSelector, lane.dest.chainSelector, "dest selector");
    assertEq(args.allowlistEnabled, false, "example lane has allowlist disabled");
    assertEq(args.addedAllowlistedSenders.length, 0, "no adds in example");
    assertEq(args.removedAllowlistedSenders.length, 0, "no removes in example");
  }

  // ---- reconciliation end to end ----

  function test_reconcile_removesAnUndeclaredSender() public {
    assertTrue(_apply(true, _pair(SENDER_A, SENDER_B)), "setup failed");
    Types.LaneConfig memory lane = _selectableLane(SRC_ALIAS, DEST, VERSION_TAG);
    lane.allowlist.allowedSenders = _single(SENDER_A);

    (BaseVerifier.AllowlistConfigArgs[] memory args, uint256 matched) =
      script.argsFor(_oneLane(lane), SRC_ALIAS, VERSION_TAG, address(verifier));
    assertEq(matched, 1, "lane matched");
    assertEq(args.length, 1, "staged");
    assertEq(args[0].removedAllowlistedSenders.length, 1, "B removed");
    assertEq(args[0].addedAllowlistedSenders.length, 0, "A already present");

    (bool ok,) = address(verifier).call(script.callFor(address(verifier), args).data);
    assertTrue(ok, "apply failed");
    address[] memory senders = _allowedSenders();
    assertEq(senders.length, 1, "one sender remains");
    assertEq(senders[0], SENDER_A, "remaining sender is A");
    assertTrue(script.isCurrent(address(verifier), lane), "current after reconciling");
  }

  /// @dev Removals apply even with the flag off, so disabling with an empty desired set
  ///      also clears residual members rather than leaving a dormant list behind.
  function test_reconcile_disablingWithEmptySetClearsResidualSenders() public {
    assertTrue(_apply(true, _single(SENDER_A)), "setup failed");
    Types.LaneConfig memory lane = _selectableLane(SRC_ALIAS, DEST, VERSION_TAG);
    lane.allowlist.allowlistEnabled = false;

    (BaseVerifier.AllowlistConfigArgs[] memory args, uint256 matched) =
      script.argsFor(_oneLane(lane), SRC_ALIAS, VERSION_TAG, address(verifier));
    assertEq(matched, 1, "lane matched");
    assertEq(args.length, 1, "staged");
    assertFalse(args[0].allowlistEnabled, "flag off");
    assertEq(args[0].removedAllowlistedSenders.length, 1, "residual A removed");

    (bool ok,) = address(verifier).call(script.callFor(address(verifier), args).data);
    assertTrue(ok, "apply failed");
    assertEq(_allowedSenders().length, 0, "set cleared");
    assertTrue(script.isCurrent(address(verifier), lane), "current after reconciling");
  }

  // ---- raw call behaviour of the audited contract ----

  function test_callFor_enablesAndAddsSenders() public {
    assertTrue(_apply(true, _pair(SENDER_A, SENDER_B)), "apply failed");

    (BaseVerifier.RemoteChainConfigArgs memory cfg, address[] memory senders) = verifier.getRemoteChainConfig(DEST);
    assertTrue(cfg.allowlistEnabled, "allowlist should be enabled");
    assertEq(senders.length, 2, "two senders allowed");
  }

  function test_reverts_whenAddingWithAllowlistDisabled() public {
    // Contract reverts InvalidAllowListRequest (adds require allowlistEnabled == true).
    assertFalse(_apply(false, _single(SENDER_A)), "should have reverted");
  }

  function test_reverts_whenCallerNotOwnerNorAllowlistAdmin() public {
    BaseScript.Call memory call = script.callFor(address(verifier), _argsFor(true, _single(SENDER_A)));
    vm.prank(address(0xBAD));
    (bool ok,) = call.to.call(call.data); // msg.sender == 0xBAD -> OnlyCallableByOwnerOrAllowlistAdmin
    assertFalse(ok, "non-owner/admin should not be able to update allowlist");
  }

  // ---- config validation: a config error, never a silent no-op ----

  function test_reverts_whenSendersListedWithAllowlistDisabled() public {
    Types.LaneConfig memory lane = _selectableLane(SRC_ALIAS, DEST, VERSION_TAG);
    lane.allowlist.allowlistEnabled = false;
    lane.allowlist.allowedSenders = _single(SENDER_A);
    vm.expectRevert("ApplyAllowlistUpdates: allowedSenders requires allowlistEnabled=true");
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    script.argsFor(_oneLane(lane), SRC_ALIAS, VERSION_TAG, address(verifier));
  }

  function test_reverts_whenSenderIsZeroAddress() public {
    Types.LaneConfig memory lane = _selectableLane(SRC_ALIAS, DEST, VERSION_TAG);
    lane.allowlist.allowedSenders = _single(address(0));
    vm.expectRevert("ApplyAllowlistUpdates: zero-address sender in allowedSenders");
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    script.argsFor(_oneLane(lane), SRC_ALIAS, VERSION_TAG, address(verifier));
  }

  function test_reverts_whenSendersDuplicated() public {
    Types.LaneConfig memory lane = _selectableLane(SRC_ALIAS, DEST, VERSION_TAG);
    lane.allowlist.allowedSenders = _pair(SENDER_A, SENDER_A);
    vm.expectRevert("ApplyAllowlistUpdates: duplicate sender in allowedSenders");
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    script.argsFor(_oneLane(lane), SRC_ALIAS, VERSION_TAG, address(verifier));
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
    lane = _lane(true, _none());
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
    // allowlistEnabled=false with no senders is the verifier's untouched state.
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
    lanes[1].allowlist.allowedSenders = _single(SENDER_B);

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
