// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ApplySignatureConfigs} from "../../script/configure/ApplySignatureConfigs.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {
  SignatureQuorumValidator
} from "@chainlink/contracts-ccip/contracts/ccvs/components/SignatureQuorumValidator.sol";

/// @dev Library internals revert in the caller's frame, so expectRevert needs this
///      external-call indirection.
contract DeploymentLookupHarness {
  function verifierByTag(
    string calldata chainAlias,
    bytes4 versionTag
  ) external view returns (address) {
    return ConfigLib.verifierByTag(ConfigLib.readDeployment(chainAlias), versionTag);
  }
}

/// @notice Exercises the ApplySignatureConfigs builder against the real audited
///         CommitteeVerifier (deployed by the fixture). The fixture makes this test
///         contract the verifier owner, so the built calldata can be executed here.
contract ApplySignatureConfigsTest is CommitteeVerifierSetup {
  ApplySignatureConfigs internal script;
  DeploymentLookupHarness internal lookup;

  string internal constant EXAMPLE_LANE = "config/lanes/sepolia-to-base_sepolia.example.json";
  // zz-scratch-* is the repo-wide fixture marker: `ConfigLib.writeDeployment` targets the
  // real config/deployments/, so records written here must be ignorable by the governance
  // tooling.
  string internal constant DEST_ALIAS = "zz-scratch-dest-chain";
  string internal constant SOURCE_ALIAS = "zz-scratch-src-chain";
  string internal constant PARTIAL_ALIAS = "zz-scratch-partial-chain";

  // Sepolia selector (matches the staging config).
  uint64 internal constant SOURCE_SELECTOR = 16015286601757825753;

  function setUp() public override {
    super.setUp();
    script = new ApplySignatureConfigs();
    lookup = new DeploymentLookupHarness();

    // The lookup harness reads the record for the alias it resolves, so it needs one.
    Types.Deployment memory deployment;
    deployment.aliasName = DEST_ALIAS;
    deployment.factory = address(factory);
    deployment.resolver = address(resolver);
    deployment.verifiers = _verifiersOf(address(verifier));
    ConfigLib.writeDeployment(deployment);
  }

  function _generateSigners(
    uint256 count
  ) internal pure returns (address[] memory signers) {
    signers = new address[](count);
    for (uint160 i = 0; i < count; ++i) {
      signers[i] = address(0x1000 + i); // distinct, non-zero, ascending
    }
  }

  function _buildSignatureConfig(
    uint8 threshold,
    address[] memory signers
  ) internal pure returns (SignatureQuorumValidator.SignatureConfig[] memory configs) {
    configs = new SignatureQuorumValidator.SignatureConfig[](1);
    configs[0] = SignatureQuorumValidator.SignatureConfig({
      sourceChainSelector: SOURCE_SELECTOR, threshold: threshold, signers: signers
    });
  }

  function _applySignatureConfig(
    uint8 threshold,
    address[] memory signers
  ) internal returns (bool ok) {
    BaseScript.Call memory call =
      script.callFor(address(verifier), new uint64[](0), _buildSignatureConfig(threshold, signers));
    assertEq(call.to, address(verifier), "target is verifier");
    (ok,) = call.to.call(call.data); // msg.sender == owner (this test)
  }

  // ---- isCurrent: what keeps a re-run from restaging applied lanes ----
  // A stale answer here either restages every committee or silently drops a rotation,
  // and neither is visible on-chain: applySignatureConfigs accepts both.

  /// @dev Reverses `_generateSigners` so set-vs-sequence comparison is exercised.
  function _reversed(
    address[] memory input
  ) internal pure returns (address[] memory out) {
    out = new address[](input.length);
    for (uint256 i = 0; i < input.length; ++i) {
      out[i] = input[input.length - 1 - i];
    }
  }

  function test_isCurrent_falseBeforeAnythingIsApplied() public view {
    assertFalse(
      script.isCurrent(address(verifier), _lane(DEST_ALIAS, 3, _generateSigners(4))),
      "unconfigured source is not current"
    );
  }

  function test_isCurrent_trueAfterApplyingTheSameCommittee() public {
    assertTrue(_applySignatureConfig(3, _generateSigners(4)), "apply failed");
    assertTrue(script.isCurrent(address(verifier), _lane(DEST_ALIAS, 3, _generateSigners(4))), "identical committee");
  }

  function test_isCurrent_ignoresSignerOrder() public {
    assertTrue(_applySignatureConfig(3, _generateSigners(4)), "apply failed");
    assertTrue(
      script.isCurrent(address(verifier), _lane(DEST_ALIAS, 3, _reversed(_generateSigners(4)))),
      "same set in another order is not a change"
    );
  }

  function test_isCurrent_falseWhenThresholdDiffers() public {
    assertTrue(_applySignatureConfig(3, _generateSigners(4)), "apply failed");
    assertFalse(script.isCurrent(address(verifier), _lane(DEST_ALIAS, 4, _generateSigners(4))), "threshold change");
  }

  function test_isCurrent_falseWhenASignerIsAdded() public {
    assertTrue(_applySignatureConfig(3, _generateSigners(4)), "apply failed");
    assertFalse(script.isCurrent(address(verifier), _lane(DEST_ALIAS, 3, _generateSigners(5))), "committee grew");
  }

  function test_isCurrent_falseWhenASignerIsSwapped() public {
    assertTrue(_applySignatureConfig(3, _generateSigners(4)), "apply failed");
    address[] memory rotated = _generateSigners(4);
    rotated[3] = address(0xBEEF);
    assertFalse(script.isCurrent(address(verifier), _lane(DEST_ALIAS, 3, rotated)), "a rotation must stage");
  }

  function test_callFor_appliesSignerSet() public {
    assertTrue(_applySignatureConfig(3, _generateSigners(4)), "apply 3-of-4 failed");

    (address[] memory got, uint8 threshold) = verifier.getSignatureConfig(SOURCE_SELECTOR);
    assertEq(threshold, 3, "threshold");
    assertEq(got.length, 4, "signer count");
  }

  function test_fullSetReplacement_overwritesPreviousSet() public {
    assertTrue(_applySignatureConfig(3, _generateSigners(4)), "initial apply failed");

    // Replace with a smaller set for the same source selector.
    address[] memory smaller = new address[](2);
    smaller[0] = address(0xBEEF);
    smaller[1] = address(0xCAFE);
    assertTrue(_applySignatureConfig(1, smaller), "replacement apply failed");

    (address[] memory got, uint8 threshold) = verifier.getSignatureConfig(SOURCE_SELECTOR);
    assertEq(threshold, 1, "threshold replaced");
    assertEq(got.length, 2, "signer set fully replaced, not merged");
    assertEq(got[0], address(0xBEEF));
    assertEq(got[1], address(0xCAFE));
  }

  function test_reverts_whenThresholdExceedsSignerCount() public {
    // threshold 3 with only 2 signers -> contract reverts InvalidSignatureConfig.
    assertFalse(_applySignatureConfig(3, _generateSigners(2)), "should have reverted on-chain");
  }

  function test_toSignatureConfig_translatesExampleLane() public view {
    // The shipped example lane is 7-of-10; verify the config->struct translation.
    Types.LaneConfig memory lane = ConfigLib.readLaneByPath(EXAMPLE_LANE);
    SignatureQuorumValidator.SignatureConfig memory cfg = script.toSignatureConfig(lane);

    assertEq(cfg.sourceChainSelector, lane.source.chainSelector);
    assertEq(cfg.threshold, 7);
    assertEq(cfg.signers.length, 10);
  }

  // ---------------------------------------------------------------------------
  //  Misconfiguration: the script's fail-fast guards. These fire BEFORE anything
  //  is broadcast, so they must produce clearer errors than the contract's own
  //  reverts. `laneCall` takes a LaneConfig struct, so these need no fixture
  //  files — the bad config is built in memory.
  // ---------------------------------------------------------------------------

  /// @dev Minimal lane carrying only the fields this script reads.
  function _oneLane(
    Types.LaneConfig memory lane
  ) internal pure returns (Types.LaneConfig[] memory lanes) {
    lanes = new Types.LaneConfig[](1);
    lanes[0] = lane;
  }

  function _lane(
    string memory destAlias,
    uint8 threshold,
    address[] memory signers
  ) internal pure returns (Types.LaneConfig memory lane) {
    lane.name = "test-lane";
    lane.source.aliasName = SOURCE_ALIAS;
    lane.source.chainSelector = SOURCE_SELECTOR;
    lane.dest.aliasName = destAlias;
    lane.dest.chainSelector = 10344971235874465080;
    lane.versionTag = VERSION_TAG;
    lane.signatureConfig.threshold = threshold;
    lane.signatureConfig.signers = signers;
  }

  function test_reverts_whenTargetVerifierNotYetDeployed() public {
    // No verifiers entry for the tag: the condition under test.
    Types.Deployment memory partialRecord;
    partialRecord.aliasName = PARTIAL_ALIAS;
    partialRecord.factory = address(factory);
    partialRecord.resolver = address(resolver);
    ConfigLib.writeDeployment(partialRecord);

    vm.expectRevert(
      bytes(
        string.concat(
          "ConfigLib: no verifier with versionTag 0x00010001 recorded for ",
          PARTIAL_ALIAS,
          " - deploy that verifier first"
        )
      )
    );
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    lookup.verifierByTag(PARTIAL_ALIAS, VERSION_TAG);
  }

  function test_missingDeploymentFile_surfacesRawCheatcodeError() public view {
    try lookup.verifierByTag("test_unrecorded_chain", VERSION_TAG) {
      revert("expected a revert for a missing deployment record");
    } catch (bytes memory) {
      // Reverts, but NOT with the script's message. Asserting only that it fails.
    }
  }

  function test_reverts_whenThresholdExceedsSignerCount_failsFast() public {
    vm.expectRevert("ApplySignatureConfigs: threshold must be in [1, signers.length]");
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    script.configsFor(_oneLane(_lane(DEST_ALIAS, 5, _generateSigners(4))), DEST_ALIAS, VERSION_TAG, address(verifier));
  }

  function test_reverts_whenThresholdIsZero() public {
    vm.expectRevert("ApplySignatureConfigs: threshold must be in [1, signers.length]");
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    script.configsFor(_oneLane(_lane(DEST_ALIAS, 0, _generateSigners(4))), DEST_ALIAS, VERSION_TAG, address(verifier));
  }

  // ---- committee policy: fatal unless ALLOW_WEAK_COMMITTEE waives it ----
  // None of these rules is enforced onchain, so this script is the only gate. The waiver is a
  // field rather than an env read so these stay order-independent: forge reverts EVM
  // state between tests but memoises vm.env*, so vm.setEnv could not be undone.

  function test_reverts_on1of1Committee() public {
    vm.expectRevert("ApplySignatureConfigs: 1-of-1 signer set (set ALLOW_WEAK_COMMITTEE=true for test committees)");
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    script.configsFor(_oneLane(_lane(DEST_ALIAS, 1, _generateSigners(1))), DEST_ALIAS, VERSION_TAG, address(verifier));
  }

  function test_reverts_whenThresholdDoesNotExceedTwoThirds() public {
    // 2-of-3: 2*3 == 6, not > 3*2 == 6.
    vm.expectRevert(
      "ApplySignatureConfigs: threshold must exceed 2/3 of the committee (set ALLOW_WEAK_COMMITTEE=true for test committees)"
    );
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    script.configsFor(_oneLane(_lane(DEST_ALIAS, 2, _generateSigners(3))), DEST_ALIAS, VERSION_TAG, address(verifier));
  }

  function test_reverts_onNofNCommittee() public {
    // 4-of-4 clears the 2/3 rule but one offline signer halts the lane.
    vm.expectRevert(
      "ApplySignatureConfigs: N-of-N committee has no redundancy, one offline signer halts the lane (set ALLOW_WEAK_COMMITTEE=true for test committees)"
    );
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    script.configsFor(_oneLane(_lane(DEST_ALIAS, 4, _generateSigners(4))), DEST_ALIAS, VERSION_TAG, address(verifier));
  }

  function test_allowWeakCommittee_waivesNofN() public {
    script.setAllowWeakCommittee(true);
    (SignatureQuorumValidator.SignatureConfig[] memory configs, uint256 matched) =
      script.configsFor(_oneLane(_lane(DEST_ALIAS, 4, _generateSigners(4))), DEST_ALIAS, VERSION_TAG, address(verifier));

    assertEq(matched, 1, "the lane matched");
    assertEq(configs.length, 1, "staged despite the weak committee");
    assertEq(configs[0].threshold, 4, "threshold carried through");
  }

  function test_allowWeakCommittee_waives1of1() public {
    script.setAllowWeakCommittee(true);
    (SignatureQuorumValidator.SignatureConfig[] memory configs, uint256 matched) =
      script.configsFor(_oneLane(_lane(DEST_ALIAS, 1, _generateSigners(1))), DEST_ALIAS, VERSION_TAG, address(verifier));

    assertEq(matched, 1, "the lane matched");
    assertEq(configs.length, 1, "staged despite the weak committee");
    assertEq(configs[0].threshold, 1, "threshold carried through");
  }

  function test_threeOfFour_passesPolicy() public view {
    // 3 < 4 and 3*3 == 9 > 4*2 == 8: the smallest committee that needs no waiver.
    (SignatureQuorumValidator.SignatureConfig[] memory configs, uint256 matched) =
      script.configsFor(_oneLane(_lane(DEST_ALIAS, 3, _generateSigners(4))), DEST_ALIAS, VERSION_TAG, address(verifier));

    assertEq(matched, 1, "the lane matched");
    assertEq(configs.length, 1, "3-of-4 is a compliant committee");
    assertEq(configs[0].sourceChainSelector, SOURCE_SELECTOR, "keyed by the lane source");
  }

  function test_reverts_whenSignerSetEmpty() public {
    vm.expectRevert("ApplySignatureConfigs: empty signer set");
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    script.configsFor(_oneLane(_lane(DEST_ALIAS, 1, new address[](0))), DEST_ALIAS, VERSION_TAG, address(verifier));
  }

  function test_reverts_whenSignerIsZeroAddress() public {
    address[] memory signers = _generateSigners(3);
    signers[1] = address(0);
    vm.expectRevert("ApplySignatureConfigs: zero-address signer");
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    script.configsFor(_oneLane(_lane(DEST_ALIAS, 2, signers)), DEST_ALIAS, VERSION_TAG, address(verifier));
  }

  function test_reverts_whenSignersDuplicated() public {
    address[] memory signers = _generateSigners(3);
    signers[2] = signers[0];
    vm.expectRevert("ApplySignatureConfigs: duplicate signer");
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    script.configsFor(_oneLane(_lane(DEST_ALIAS, 2, signers)), DEST_ALIAS, VERSION_TAG, address(verifier));
  }

  // ---------------------------------------------------------------------------
  //  configsFor: selection, skip and ordering across a lane set
  // ---------------------------------------------------------------------------

  function _laneFrom(
    string memory destAlias,
    uint64 sourceSelector,
    bytes4 tag
  ) internal pure returns (Types.LaneConfig memory lane) {
    lane = _lane(destAlias, 3, _generateSigners(4));
    lane.source.chainSelector = sourceSelector;
    lane.versionTag = tag;
  }

  function test_configsFor_skipsLanesForAnotherChain() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](2);
    lanes[0] = _laneFrom(DEST_ALIAS, SOURCE_SELECTOR, VERSION_TAG);
    lanes[1] = _laneFrom("zz-scratch-other-chain", 999, VERSION_TAG);

    (SignatureQuorumValidator.SignatureConfig[] memory configs, uint256 matched) =
      script.configsFor(lanes, DEST_ALIAS, VERSION_TAG, address(verifier));

    assertEq(matched, 1, "only the lane destined for this chain matched");
    assertEq(configs.length, 1);
    assertEq(configs[0].sourceChainSelector, SOURCE_SELECTOR);
  }

  function test_configsFor_skipsLanesPinnedToAnotherTag() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](2);
    lanes[0] = _laneFrom(DEST_ALIAS, SOURCE_SELECTOR, VERSION_TAG);
    lanes[1] = _laneFrom(DEST_ALIAS, 999, 0x00020002);

    (SignatureQuorumValidator.SignatureConfig[] memory configs, uint256 matched) =
      script.configsFor(lanes, DEST_ALIAS, VERSION_TAG, address(verifier));

    assertEq(matched, 1, "the other tag is a different verifier's business");
    assertEq(configs.length, 1);
  }

  /// @dev The array length IS the staged count: the over-allocated tail must not survive.
  function test_configsFor_lengthIsTheStagedCount() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](4);
    lanes[0] = _laneFrom(DEST_ALIAS, 111, VERSION_TAG);
    lanes[1] = _laneFrom("zz-scratch-other-chain", 222, VERSION_TAG);
    lanes[2] = _laneFrom(DEST_ALIAS, 333, VERSION_TAG);
    lanes[3] = _laneFrom(DEST_ALIAS, 444, 0x00020002);

    (SignatureQuorumValidator.SignatureConfig[] memory configs, uint256 matched) =
      script.configsFor(lanes, DEST_ALIAS, VERSION_TAG, address(verifier));

    assertEq(matched, 2, "two lanes matched the filters");
    assertEq(configs.length, 2, "trimmed from the 4-slot upper bound");
    assertEq(configs[0].sourceChainSelector, 111, "lane order preserved");
    assertEq(configs[1].sourceChainSelector, 333, "lane order preserved");
  }

  /// @dev A lane already applied on-chain counts as matched but must not be staged.
  function test_configsFor_skipsLaneAlreadyCurrentButStillCountsIt() public {
    Types.LaneConfig memory lane = _lane(DEST_ALIAS, 3, _generateSigners(4));

    // Apply it first, so isCurrent() is true on the second pass.
    SignatureQuorumValidator.SignatureConfig[] memory configs = new SignatureQuorumValidator.SignatureConfig[](1);
    configs[0] = script.toSignatureConfig(lane);
    BaseScript.Call memory call = script.callFor(address(verifier), new uint64[](0), configs);
    (bool ok,) = call.to.call(call.data);
    assertTrue(ok, "setup: applying the committee");
    assertTrue(script.isCurrent(address(verifier), lane), "setup: now current");

    (SignatureQuorumValidator.SignatureConfig[] memory staged, uint256 matched) =
      script.configsFor(_oneLane(lane), DEST_ALIAS, VERSION_TAG, address(verifier));

    assertEq(matched, 1, "the lane still matched the filters");
    assertEq(staged.length, 0, "but nothing to stage");
  }

  function test_configsFor_matchesNothingWhenNoLaneTargetsTheChain() public view {
    (SignatureQuorumValidator.SignatureConfig[] memory configs, uint256 matched) = script.configsFor(
      _oneLane(_laneFrom("zz-scratch-other-chain", SOURCE_SELECTOR, VERSION_TAG)),
      DEST_ALIAS,
      VERSION_TAG,
      address(verifier)
    );

    assertEq(matched, 0, "run() turns this into its no-lanes revert");
    assertEq(configs.length, 0);
  }

  /// @dev The point of batching: two matched lanes become ONE call that applies both.
  function test_batchedCall_appliesEveryMatchedLaneInOneCall() public {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](2);
    lanes[0] = _laneFrom(DEST_ALIAS, 111, VERSION_TAG);
    lanes[1] = _laneFrom(DEST_ALIAS, 222, VERSION_TAG);

    (SignatureQuorumValidator.SignatureConfig[] memory configs, uint256 matched) =
      script.configsFor(lanes, DEST_ALIAS, VERSION_TAG, address(verifier));
    assertEq(matched, 2);
    assertEq(configs.length, 2, "both lanes staged");

    BaseScript.Call memory call = script.callFor(address(verifier), new uint64[](0), configs);
    (bool ok,) = call.to.call(call.data);
    assertTrue(ok, "the single batched call applied");

    assertTrue(script.isCurrent(address(verifier), lanes[0]), "source 111 configured");
    assertTrue(script.isCurrent(address(verifier), lanes[1]), "source 222 configured");
  }
}
