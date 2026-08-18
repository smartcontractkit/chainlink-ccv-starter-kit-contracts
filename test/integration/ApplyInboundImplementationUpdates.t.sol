// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ApplyInboundImplementationUpdates} from "../../script/configure/ApplyInboundImplementationUpdates.s.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";

/// @notice Exercises the ApplyInboundImplementationUpdates builder against the real
///         audited VersionedVerifierResolver (deployed by the fixture, owned by this test).
contract ApplyInboundImplementationUpdatesTest is CommitteeVerifierSetup {
  ApplyInboundImplementationUpdates internal script;

  bytes4 internal constant VERSION = 0x00010001;

  function setUp() public override {
    super.setUp();
    script = new ApplyInboundImplementationUpdates();
  }

  function _applyInbound(bytes4 version, address impl) internal returns (bool ok) {
    BaseScript.Call[] memory calls = script.callsFor(address(resolver), script.toInboundArgs(version, impl));
    assertEq(calls.length, 1, "one call expected");
    assertEq(calls[0].to, address(resolver), "target is resolver");
    (ok,) = calls[0].to.call(calls[0].data); // msg.sender == owner (this test)
  }

  function _inboundImpl(bytes4 version) internal view returns (address) {
    return resolver.getInboundImplementation(abi.encodePacked(version));
  }

  function test_callsFor_setsInboundImplementation() public {
    assertTrue(_applyInbound(VERSION, address(verifier)), "apply failed");
    assertEq(_inboundImpl(VERSION), address(verifier), "version -> verifier mapping");
  }

  function test_zeroVerifier_clearsMapping() public {
    assertTrue(_applyInbound(VERSION, address(verifier)), "set failed");
    assertTrue(_applyInbound(VERSION, address(0)), "clear failed");
    assertEq(_inboundImpl(VERSION), address(0), "mapping cleared");
  }

  function test_reverts_whenVersionZeroWithNonZeroVerifier() public {
    // version == 0 with a non-zero verifier -> InvalidVersion.
    assertFalse(_applyInbound(bytes4(0), address(verifier)), "should have reverted");
  }

  function test_reverts_whenCallerNotOwner() public {
    BaseScript.Call[] memory calls = script.callsFor(address(resolver), script.toInboundArgs(VERSION, address(verifier)));
    vm.prank(address(0xBAD));
    (bool ok,) = calls[0].to.call(calls[0].data); // onlyOwner
    assertFalse(ok, "non-owner should not update inbound implementations");
  }

  function test_toInboundArgs_translatesFields() public view {
    VersionedVerifierResolver.InboundImplementationArgs[] memory args = script.toInboundArgs(VERSION, address(verifier));
    assertEq(args.length, 1);
    assertEq(args[0].version, VERSION);
    assertEq(args[0].verifier, address(verifier));
  }
}