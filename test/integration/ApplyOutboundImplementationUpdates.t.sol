// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ApplyOutboundImplementationUpdates} from "../../script/configure/ApplyOutboundImplementationUpdates.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
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
    BaseScript.Call[] memory calls = script.callsFor(address(resolver), args);
    assertEq(calls.length, 1, "one call expected");
    assertEq(calls[0].to, address(resolver), "target is resolver");
    (ok,) = calls[0].to.call(calls[0].data); // msg.sender == owner (this test)
  }

  function _outboundImpl(
    uint64 destSelector
  ) internal view returns (address) {
    return resolver.getOutboundImplementation(destSelector, "");
  }

  function test_callsFor_setsOutboundImplementation() public {
    assertTrue(_applyOutbound(_singleArg(DEST_FUJI, address(verifier))), "apply failed");
    assertEq(_outboundImpl(DEST_FUJI), address(verifier), "dest -> verifier mapping");
  }

  function test_appliesMultipleDestinationsInOneCall() public {
    VersionedVerifierResolver.OutboundImplementationArgs[] memory args =
      new VersionedVerifierResolver.OutboundImplementationArgs[](2);
    args[0] =
      VersionedVerifierResolver.OutboundImplementationArgs({destChainSelector: DEST_FUJI, verifier: address(verifier)});
    args[1] =
      VersionedVerifierResolver.OutboundImplementationArgs({destChainSelector: DEST_AMOY, verifier: address(verifier)});

    assertTrue(_applyOutbound(args), "batch apply failed");
    assertEq(_outboundImpl(DEST_FUJI), address(verifier), "fuji mapped");
    assertEq(_outboundImpl(DEST_AMOY), address(verifier), "amoy mapped");
  }

  function test_zeroVerifier_clearsMapping() public {
    assertTrue(_applyOutbound(_singleArg(DEST_FUJI, address(verifier))), "set failed");
    assertTrue(_applyOutbound(_singleArg(DEST_FUJI, address(0))), "clear failed");
    assertEq(_outboundImpl(DEST_FUJI), address(0), "mapping cleared");
  }

  function test_reverts_whenDestSelectorZeroWithNonZeroVerifier() public {
    assertFalse(_applyOutbound(_singleArg(0, address(verifier))), "should have reverted");
  }

  function test_reverts_whenCallerNotOwner() public {
    BaseScript.Call[] memory calls = script.callsFor(address(resolver), _singleArg(DEST_FUJI, address(verifier)));
    vm.prank(address(0xBAD));
    (bool ok,) = calls[0].to.call(calls[0].data); // onlyOwner
    assertFalse(ok, "non-owner should not update outbound implementations");
  }
}
