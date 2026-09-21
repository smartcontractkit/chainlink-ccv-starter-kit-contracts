// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SetAllowedFinalityConfig} from "../../script/configure/SetAllowedFinalityConfig.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {FinalityConfigLib} from "../../src/lib/FinalityConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";

/// @notice Exercises the SetAllowedFinalityConfig builder against the real audited
///         CommitteeVerifier (deployed by the fixture, owned by this test).
contract SetAllowedFinalityConfigTest is CommitteeVerifierSetup {
  SetAllowedFinalityConfig internal script;

  // Sourced from the codec so the test cannot drift from the encoding it asserts.
  bytes4 internal constant FULL_FINALITY = FinalityCodec.WAIT_FOR_FINALITY_FLAG;
  bytes4 internal constant WAIT_FOR_SAFE = FinalityCodec.WAIT_FOR_SAFE_FLAG;
  bytes4 internal constant BLOCK_DEPTH_1 = bytes4(uint32(1));
  bytes4 internal constant SAFE_OR_DEPTH_1 = WAIT_FOR_SAFE | BLOCK_DEPTH_1;

  function setUp() public override {
    super.setUp();
    script = new SetAllowedFinalityConfig();
  }

  function _applyFinality(
    bytes4 value
  ) internal returns (bool ok) {
    BaseScript.Call memory call = script.callFor(address(verifier), value);
    assertEq(call.to, address(verifier), "target is verifier");
    (ok,) = call.to.call(call.data); // msg.sender == owner (this test)
  }

  function test_callFor_setsFastPathFinality() public {
    assertTrue(_applyFinality(BLOCK_DEPTH_1), "apply failed");
    assertEq(verifier.getAllowedFinalityConfig(), BLOCK_DEPTH_1, "finality config set");
  }

  function test_setFullFinality() public {
    // Set fast-path first, then tighten to full finality.
    assertTrue(_applyFinality(BLOCK_DEPTH_1), "apply fast-path failed");
    assertTrue(_applyFinality(FULL_FINALITY), "apply full finality failed");
    assertEq(verifier.getAllowedFinalityConfig(), FULL_FINALITY, "finality tightened to full");
  }

  function test_reverts_whenCallerNotOwner() public {
    BaseScript.Call memory call = script.callFor(address(verifier), BLOCK_DEPTH_1);
    vm.prank(address(0xBAD));
    (bool ok,) = call.to.call(call.data); // onlyOwner
    assertFalse(ok, "non-owner should not set finality config");
  }

  /// @dev The typed block is what an operator writes; the verifier must store exactly the
  ///      value the codec would check a request against.
  function test_encodedConfig_isWhatTheVerifierStores() public {
    Types.AllowedFinality memory finality = Types.AllowedFinality({allowSafeTag: true, minBlockDepth: 1});
    assertTrue(_applyFinality(FinalityConfigLib.encode(finality)), "apply failed");
    assertEq(verifier.getAllowedFinalityConfig(), SAFE_OR_DEPTH_1, "safe tag or depth >= 1");
  }

  // ---- finality policy: fatal unless ALLOW_WEAK_FINALITY waives it ----
  // The waiver is a field rather than an env read so these stay order-independent: forge
  // reverts EVM state between tests but memoises vm.env*, so vm.setEnv could not be undone.

  function test_fullFinality_passesWithoutWaiver() public view {
    script.validateFinalityPolicy(FULL_FINALITY);
  }

  function test_reverts_belowFullFinality() public {
    vm.expectRevert(bytes(script.WEAK_FINALITY_ERROR()));
    script.validateFinalityPolicy(BLOCK_DEPTH_1);

    vm.expectRevert(bytes(script.WEAK_FINALITY_ERROR()));
    script.validateFinalityPolicy(WAIT_FOR_SAFE);
  }

  function test_allowWeakFinality_waivesEveryFastPath() public {
    script.setAllowWeakFinality(true);
    script.validateFinalityPolicy(BLOCK_DEPTH_1);
    script.validateFinalityPolicy(WAIT_FOR_SAFE);
    script.validateFinalityPolicy(SAFE_OR_DEPTH_1);
  }

  /// @dev Guards the robust bytes4 parser: a 4-byte hex value must round-trip exactly
  ///      (independent of Foundry's fixed-bytes padding convention). The operator example
  ///      covers the typed finality block, which must load as full finality only.
  function test_configReaders_parseExampleFilesExactly() public view {
    Types.OperatorConfig memory operator = ConfigLib.readOperatorByPath("config/operator/chains/sepolia.example.json");
    assertEq(
      FinalityConfigLib.encode(operator.verifiers[0].allowedFinality),
      FULL_FINALITY,
      "empty block is full finality only"
    );

    Types.LaneConfig memory lane =
      ConfigLib.readLaneByPath("config/operator/lanes/sepolia-to-base_sepolia.example.json");
    assertEq(lane.versionTag, bytes4(0x00010001), "versionTag parsed exactly");
  }
}
