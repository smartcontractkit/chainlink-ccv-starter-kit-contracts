// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SetAllowedFinalityConfig} from "../../script/configure/SetAllowedFinalityConfig.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
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
  bytes4 internal constant MAX_DEPTH = FinalityCodec.BLOCK_DEPTH_MASK;
  bytes4 internal constant BLOCK_DEPTH_1 = bytes4(uint32(1));
  bytes4 internal constant SAFE_OR_DEPTH_1 = WAIT_FOR_SAFE | BLOCK_DEPTH_1;

  function setUp() public override {
    super.setUp();
    script = new SetAllowedFinalityConfig();
  }

  function _applyFinality(
    bytes4 value
  ) internal returns (bool ok) {
    BaseScript.Call[] memory calls = script.callsFor(address(verifier), value);
    assertEq(calls.length, 1, "one call expected");
    assertEq(calls[0].to, address(verifier), "target is verifier");
    (ok,) = calls[0].to.call(calls[0].data); // msg.sender == owner (this test)
  }

  function test_callsFor_setsFastPathFinality() public {
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
    BaseScript.Call[] memory calls = script.callsFor(address(verifier), BLOCK_DEPTH_1);
    vm.prank(address(0xBAD));
    (bool ok,) = calls[0].to.call(calls[0].data); // onlyOwner
    assertFalse(ok, "non-owner should not set finality config");
  }

  // --------------------------------------------------------------------------
  //  encoding validation
  // --------------------------------------------------------------------------
  /// @dev Reserved bits 17-31 are unassigned, so a value setting them expresses no mode
  ///      that exists. FinalityCodec accepts unknown flags on the wire, but here the value
  ///      is hand-written config, where a reserved bit is a typo.
  function test_validateEncoding_rejectsReservedBits() public {
    vm.expectRevert(bytes(script.RESERVED_BITS_ERROR()));
    script.validateEncoding(bytes4(0xDEADBEEF));

    vm.expectRevert(bytes(script.RESERVED_BITS_ERROR()));
    script.validateEncoding(bytes4(0xFFFFFFFF));
  }

  /// @dev `allowedFinality` may combine a flag with a depth — that is what
  ///      `FinalityCodec._encodeBlockDepthAndSafeFlag` produces, and it is valid here even
  ///      though a sender's REQUESTED finality may only carry one mode. Applying the
  ///      single-mode rule would reject legitimate config, so these must all pass.
  function test_validateEncoding_acceptsEveryAssignedShape() public view {
    script.validateEncoding(FULL_FINALITY); // 0x00000000
    script.validateEncoding(BLOCK_DEPTH_1); // depth 1
    script.validateEncoding(MAX_DEPTH); // max depth
    script.validateEncoding(WAIT_FOR_SAFE); // safe flag, no depth
    script.validateEncoding(SAFE_OR_DEPTH_1); // safe flag + depth
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

  /// @dev The waiver relaxes policy, not the encoding: a reserved bit stays fatal.
  function test_allowWeakFinality_doesNotWaiveReservedBits() public {
    script.setAllowWeakFinality(true);
    vm.expectRevert(bytes(script.RESERVED_BITS_ERROR()));
    script.validateFinalityPolicy(bytes4(0xDEADBEEF));
  }

  /// @dev Guards the robust bytes4 parser: a 4-byte hex value must round-trip exactly
  ///      (independent of Foundry's fixed-bytes padding convention).
  function test_readChainByPath_parsesBytes4FieldsExactly() public view {
    Types.ChainConfig memory chainConfig = ConfigLib.readChainByPath("config/chains/sepolia.example.json");
    assertEq(chainConfig.versionTag, bytes4(0x00010001), "versionTag parsed exactly");
    assertEq(chainConfig.finalityConfig, bytes4(0), "finalityConfig parsed exactly (full finality)");
  }
}
