// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ApplyOutboundImplementationUpdates} from "../../script/configure/ApplyOutboundImplementationUpdates.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";

/// @notice Exercises the ApplyOutboundImplementationUpdates builder against the real
///         audited VersionedVerifierResolver (deployed by the fixture, owned by this test).
contract ApplyOutboundImplementationUpdatesTest is CommitteeVerifierSetup {
  ApplyOutboundImplementationUpdates internal script;

  uint64 internal constant DEST_FUJI = 14767482510784806043;
  uint64 internal constant DEST_AMOY = 16281711391670634445;

  function setUp() public override {
    super.setUp();
    script = new ApplyOutboundImplementationUpdates();
  }

  function _singleArg(
    uint64 destSelector,
    address impl
  ) internal pure returns (VersionedVerifierResolver.OutboundImplementationArgs[] memory args) {
    args = new VersionedVerifierResolver.OutboundImplementationArgs[](1);
    args[0] = VersionedVerifierResolver.OutboundImplementationArgs({destChainSelector: destSelector, verifier: impl});
  }

  function _applyOutbound(
    VersionedVerifierResolver.OutboundImplementationArgs[] memory args
  ) internal returns (bool ok) {
    BaseScript.Call memory call = script.callFor(address(resolver), args);
    assertEq(call.to, address(resolver), "target is resolver");
    (ok,) = call.to.call(call.data); // msg.sender == owner (this test)
  }

  function _outboundImplementation(
    uint64 destSelector
  ) internal view returns (address) {
    return resolver.getOutboundImplementation(destSelector, "");
  }

  function test_callFor_setsOutboundImplementation() public {
    assertTrue(_applyOutbound(_singleArg(DEST_FUJI, address(verifier))), "apply failed");
    assertEq(_outboundImplementation(DEST_FUJI), address(verifier), "dest -> verifier mapping");
  }

  function test_appliesMultipleDestinationsInOneCall() public {
    VersionedVerifierResolver.OutboundImplementationArgs[] memory args =
      new VersionedVerifierResolver.OutboundImplementationArgs[](2);
    args[0] =
      VersionedVerifierResolver.OutboundImplementationArgs({destChainSelector: DEST_FUJI, verifier: address(verifier)});
    args[1] =
      VersionedVerifierResolver.OutboundImplementationArgs({destChainSelector: DEST_AMOY, verifier: address(verifier)});

    assertTrue(_applyOutbound(args), "batch apply failed");
    assertEq(_outboundImplementation(DEST_FUJI), address(verifier), "fuji mapped");
    assertEq(_outboundImplementation(DEST_AMOY), address(verifier), "amoy mapped");
  }

  function test_zeroVerifier_clearsMapping() public {
    assertTrue(_applyOutbound(_singleArg(DEST_FUJI, address(verifier))), "set failed");
    assertTrue(_applyOutbound(_singleArg(DEST_FUJI, address(0))), "clear failed");
    assertEq(_outboundImplementation(DEST_FUJI), address(0), "mapping cleared");
  }

  function test_reverts_whenDestSelectorZeroWithNonZeroVerifier() public {
    assertFalse(_applyOutbound(_singleArg(0, address(verifier))), "should have reverted");
  }

  // ---- isCurrent: what keeps a re-run from restaging applied destinations ----
  // The write never reverts on a matching entry, so nothing on-chain forces this to be
  // right — a wrong answer either restages every lane or silently skips a real change.

  function test_isCurrent_falseBeforeAnythingIsApplied() public view {
    assertFalse(script.isCurrent(address(resolver), DEST_FUJI, address(verifier)), "unset destination is not current");
  }

  function test_isCurrent_trueAfterApply() public {
    assertTrue(_applyOutbound(_singleArg(DEST_FUJI, address(verifier))), "apply failed");
    assertTrue(script.isCurrent(address(resolver), DEST_FUJI, address(verifier)), "applied destination is current");
  }

  function test_isCurrent_falseWhenMappedToADifferentVerifier() public {
    assertTrue(_applyOutbound(_singleArg(DEST_FUJI, address(0xBEEF))), "apply failed");
    assertFalse(
      script.isCurrent(address(resolver), DEST_FUJI, address(verifier)), "a different verifier must not read as current"
    );
  }

  function test_isCurrent_isPerDestination() public {
    assertTrue(_applyOutbound(_singleArg(DEST_FUJI, address(verifier))), "apply failed");
    assertFalse(script.isCurrent(address(resolver), DEST_AMOY, address(verifier)), "an untouched destination");
  }

  function test_isCurrent_falseAfterMappingCleared() public {
    assertTrue(_applyOutbound(_singleArg(DEST_FUJI, address(verifier))), "set failed");
    assertTrue(_applyOutbound(_singleArg(DEST_FUJI, address(0))), "clear failed");
    assertFalse(script.isCurrent(address(resolver), DEST_FUJI, address(verifier)), "cleared destination needs writing");
  }

  function test_reverts_whenCallerNotOwner() public {
    BaseScript.Call memory call = script.callFor(address(resolver), _singleArg(DEST_FUJI, address(verifier)));
    vm.prank(address(0xBAD));
    (bool ok,) = call.to.call(call.data); // onlyOwner
    assertFalse(ok, "non-owner should not update outbound implementations");
  }

  // ---------------------------------------------------------------------------
  //  argsFor: selection, skip and ordering across a lane set
  // ---------------------------------------------------------------------------

  string internal constant SRC_ALIAS = "zz-scratch-src-chain";

  function _deployment() internal view returns (Types.Deployment memory deployment) {
    deployment.aliasName = SRC_ALIAS;
    deployment.resolver = address(resolver);
    deployment.verifiers = _verifiersOf(address(verifier));
  }

  function _outboundLane(
    string memory sourceAlias,
    uint64 destSelector,
    bytes4 tag
  ) internal pure returns (Types.LaneConfig memory lane) {
    lane.name = "test-lane";
    lane.source.aliasName = sourceAlias;
    lane.dest.chainSelector = destSelector;
    lane.versionTag = tag;
  }

  function test_argsFor_skipsLanesFromAnotherChain() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](2);
    lanes[0] = _outboundLane(SRC_ALIAS, DEST_FUJI, VERSION_TAG);
    lanes[1] = _outboundLane("zz-scratch-other-chain", DEST_AMOY, VERSION_TAG);

    (VersionedVerifierResolver.OutboundImplementationArgs[] memory args, uint256 matched) =
      script.argsFor(lanes, SRC_ALIAS, _deployment());

    assertEq(matched, 1, "only the lane sourced on this chain matched");
    assertEq(args.length, 1);
    assertEq(args[0].destChainSelector, DEST_FUJI);
    assertEq(args[0].verifier, address(verifier), "mapped to the verifier serving its tag");
  }

  /// @dev The array length IS the staged count: the over-allocated tail must not survive.
  function test_argsFor_lengthIsTheStagedCount() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](3);
    lanes[0] = _outboundLane(SRC_ALIAS, DEST_FUJI, VERSION_TAG);
    lanes[1] = _outboundLane("zz-scratch-other-chain", 999, VERSION_TAG);
    lanes[2] = _outboundLane(SRC_ALIAS, DEST_AMOY, VERSION_TAG);

    (VersionedVerifierResolver.OutboundImplementationArgs[] memory args, uint256 matched) =
      script.argsFor(lanes, SRC_ALIAS, _deployment());

    assertEq(matched, 2, "two lanes matched the filter");
    assertEq(args.length, 2, "trimmed from the 3-slot upper bound");
    assertEq(args[0].destChainSelector, DEST_FUJI, "lane order preserved");
    assertEq(args[1].destChainSelector, DEST_AMOY, "lane order preserved");
  }

  /// @dev A destination already routed to that verifier counts as matched, stages nothing.
  function test_argsFor_skipsDestinationAlreadyCurrentButStillCountsIt() public {
    assertTrue(_applyOutbound(_singleArg(DEST_FUJI, address(verifier))), "setup: apply failed");

    (VersionedVerifierResolver.OutboundImplementationArgs[] memory args, uint256 matched) =
      script.argsFor(_oneLane(_outboundLane(SRC_ALIAS, DEST_FUJI, VERSION_TAG)), SRC_ALIAS, _deployment());

    assertEq(matched, 1, "the lane still matched");
    assertEq(args.length, 0, "but nothing to stage");
  }

  function test_argsFor_revertsOnZeroDestSelector() public {
    vm.expectRevert("ApplyOutboundImplementationUpdates: destChainSelector cannot be zero");
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    script.argsFor(_oneLane(_outboundLane(SRC_ALIAS, 0, VERSION_TAG)), SRC_ALIAS, _deployment());
  }

  /// @dev The point of batching: two matched lanes become ONE call that applies both.
  function test_batchedCall_appliesEveryMatchedLaneInOneCall() public {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](2);
    lanes[0] = _outboundLane(SRC_ALIAS, DEST_FUJI, VERSION_TAG);
    lanes[1] = _outboundLane(SRC_ALIAS, DEST_AMOY, VERSION_TAG);

    (VersionedVerifierResolver.OutboundImplementationArgs[] memory args, uint256 matched) =
      script.argsFor(lanes, SRC_ALIAS, _deployment());
    assertEq(matched, 2);
    assertEq(args.length, 2, "both lanes staged");

    assertTrue(_applyOutbound(args), "the single batched call applied");
    assertEq(_outboundImplementation(DEST_FUJI), address(verifier));
    assertEq(_outboundImplementation(DEST_AMOY), address(verifier));
  }

  function _oneLane(
    Types.LaneConfig memory lane
  ) internal pure returns (Types.LaneConfig[] memory lanes) {
    lanes = new Types.LaneConfig[](1);
    lanes[0] = lane;
  }
}
