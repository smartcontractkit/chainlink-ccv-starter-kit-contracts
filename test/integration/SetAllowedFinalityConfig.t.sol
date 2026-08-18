// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {SetAllowedFinalityConfig} from "../../script/configure/SetAllowedFinalityConfig.s.sol";

/// @notice Exercises the SetAllowedFinalityConfig builder against the real audited
///         CommitteeVerifier (deployed by the fixture, owned by this test).
contract SetAllowedFinalityConfigTest is CommitteeVerifierSetup {
  SetAllowedFinalityConfig internal script;

  bytes4 internal constant FULL_FINALITY = bytes4(0);
  bytes4 internal constant BLOCK_DEPTH_1 = bytes4(0x00000001);

  function setUp() public override {
    super.setUp();
    script = new SetAllowedFinalityConfig();
  }

  function _applyFinality(bytes4 value) internal returns (bool ok) {
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

  /// @dev Guards the robust bytes4 parser: a 4-byte hex value must round-trip exactly
  ///      (independent of Foundry's fixed-bytes padding convention).
  function test_readChainByPath_parsesBytes4FieldsExactly() public view {
    Types.ChainConfig memory cc = ConfigLib.readChainByPath("config/chains/sepolia.example.json");
    assertEq(cc.versionTag, bytes4(0x00010001), "versionTag parsed exactly");
    assertEq(cc.finalityConfig, bytes4(0x00000001), "finalityConfig parsed exactly");
  }
}