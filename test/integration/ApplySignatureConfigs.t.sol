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

/// @notice Exercises the ApplySignatureConfigs builder against the real audited
///         CommitteeVerifier (deployed by the fixture). The fixture makes this test
///         contract the verifier owner, so the built calldata can be executed here.
contract ApplySignatureConfigsTest is CommitteeVerifierSetup {
  ApplySignatureConfigs internal script;

  string internal constant EXAMPLE_LANE = "config/lanes/sepolia-to-base_sepolia.example.json";
  string internal constant DEST_ALIAS = "test_dest_chain";
  string internal constant SRC_ALIAS = "test_src_chain";
  string internal constant PARTIAL_ALIAS = "test_partial_chain";

  // Sepolia selector (matches the staging config).
  uint64 internal constant SRC = 16015286601757825753;

  function setUp() public override {
    super.setUp();
    script = new ApplySignatureConfigs();

    // `laneCalls` reads the record for the alias it resolves, so the target needs one.
    ConfigLib.writeDeployment(
      Types.Deployment({
        aliasName: DEST_ALIAS, factory: address(factory), resolver: address(resolver), verifier: address(verifier)
      })
    );
  }

  function _generateSigners(
    uint256 count
  ) internal pure returns (address[] memory signers) {
    signers = new address[](count);
    for (uint160 i; i < count; ++i) {
      signers[i] = address(0x1000 + i); // distinct, non-zero, ascending
    }
  }

  function _buildSignatureConfig(
    uint8 threshold,
    address[] memory signers
  ) internal pure returns (SignatureQuorumValidator.SignatureConfig[] memory configs) {
    configs = new SignatureQuorumValidator.SignatureConfig[](1);
    configs[0] =
      SignatureQuorumValidator.SignatureConfig({sourceChainSelector: SRC, threshold: threshold, signers: signers});
  }

  function _applySignatureConfig(
    uint8 threshold,
    address[] memory signers
  ) internal returns (bool ok) {
    BaseScript.Call[] memory calls =
      script.callsFor(address(verifier), new uint64[](0), _buildSignatureConfig(threshold, signers));
    assertEq(calls.length, 1, "one call expected");
    assertEq(calls[0].to, address(verifier), "target is verifier");
    (ok,) = calls[0].to.call(calls[0].data); // msg.sender == owner (this test)
  }

  function test_callsFor_appliesSignerSet() public {
    assertTrue(_applySignatureConfig(3, _generateSigners(4)), "apply 3-of-4 failed");

    (address[] memory got, uint8 threshold) = verifier.getSignatureConfig(SRC);
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

    (address[] memory got, uint8 threshold) = verifier.getSignatureConfig(SRC);
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
    SignatureQuorumValidator.SignatureConfig[] memory cfgs = script.toSignatureConfig(lane);

    assertEq(cfgs.length, 1);
    assertEq(cfgs[0].sourceChainSelector, lane.source.chainSelector);
    assertEq(cfgs[0].threshold, 7);
    assertEq(cfgs[0].signers.length, 10);
  }

  // ---------------------------------------------------------------------------
  //  Misconfiguration: the script's fail-fast guards. These fire BEFORE anything
  //  is broadcast, so they must produce clearer errors than the contract's own
  //  reverts. `laneCalls` takes a LaneConfig struct, so these need no fixture
  //  files — the bad config is built in memory.
  // ---------------------------------------------------------------------------

  /// @dev Minimal lane carrying only the fields this script reads.
  function _lane(
    string memory destAlias,
    uint8 threshold,
    address[] memory signers
  ) internal pure returns (Types.LaneConfig memory lane) {
    lane.name = "test-lane";
    lane.source.aliasName = SRC_ALIAS;
    lane.source.chainSelector = SRC;
    lane.dest.aliasName = destAlias;
    lane.dest.chainSelector = 10344971235874465080;
    lane.sig.threshold = threshold;
    lane.sig.signers = signers;
  }

  function test_reverts_whenTargetVerifierNotYetDeployed() public {
    ConfigLib.writeDeployment(
      Types.Deployment({
        aliasName: PARTIAL_ALIAS, factory: address(factory), resolver: address(resolver), verifier: address(0)
      })
    );

    vm.expectRevert(bytes(string.concat("ApplySignatureConfigs: verifier not recorded for ", PARTIAL_ALIAS)));
    script.laneCalls(_lane(PARTIAL_ALIAS, 3, _generateSigners(4)));
  }

  function test_missingDeploymentFile_surfacesRawCheatcodeError() public view {
    Types.LaneConfig memory lane = _lane("test_unrecorded_chain", 3, _generateSigners(4));
    try script.laneCalls(lane) {
      revert("expected a revert for a missing deployment record");
    } catch (bytes memory) {
      // Reverts, but NOT with the script's message. Asserting only that it fails.
    }
  }

  function test_reverts_whenThresholdExceedsSignerCount_failsFast() public {
    vm.expectRevert("ApplySignatureConfigs: threshold must be in [1, signers.length]");
    script.laneCalls(_lane(DEST_ALIAS, 5, _generateSigners(4)));
  }

  function test_reverts_whenThresholdIsZero() public {
    vm.expectRevert("ApplySignatureConfigs: threshold must be in [1, signers.length]");
    script.laneCalls(_lane(DEST_ALIAS, 0, _generateSigners(4)));
  }

  function test_reverts_whenSignerSetEmpty() public {
    vm.expectRevert("ApplySignatureConfigs: empty signer set");
    script.laneCalls(_lane(DEST_ALIAS, 1, new address[](0)));
  }

  function test_reverts_whenSignerIsZeroAddress() public {
    address[] memory signers = _generateSigners(3);
    signers[1] = address(0);
    vm.expectRevert("ApplySignatureConfigs: zero-address signer");
    script.laneCalls(_lane(DEST_ALIAS, 2, signers));
  }

  function test_reverts_whenSignersDuplicated() public {
    address[] memory signers = _generateSigners(3);
    signers[2] = signers[0];
    vm.expectRevert("ApplySignatureConfigs: duplicate signer");
    script.laneCalls(_lane(DEST_ALIAS, 2, signers));
  }
}
