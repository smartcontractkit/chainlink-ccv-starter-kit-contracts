// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SetFeeAggregator} from "../../script/configure/SetFeeAggregator.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";

/// @notice Exercises the resolver SetFeeAggregator builder against the real audited
///         VersionedVerifierResolver (deployed by the fixture, owned by this test).
contract SetFeeAggregatorTest is CommitteeVerifierSetup {
  SetFeeAggregator internal script;

  address internal constant RESOLVER_FEE_AGG = address(0xFEE2);

  function setUp() public override {
    super.setUp();
    script = new SetFeeAggregator();
  }

  function _applyFeeAggregator(
    address feeAggregator
  ) internal returns (bool ok) {
    BaseScript.Call[] memory calls = script.callsFor(address(resolver), feeAggregator);
    assertEq(calls.length, 1, "one call expected");
    assertEq(calls[0].to, address(resolver), "target is resolver");
    (ok,) = calls[0].to.call(calls[0].data); // msg.sender == owner (this test)
  }

  function test_callsFor_setsResolverFeeAggregator() public {
    assertTrue(_applyFeeAggregator(RESOLVER_FEE_AGG), "apply failed");
    assertEq(resolver.getFeeAggregator(), RESOLVER_FEE_AGG, "resolver feeAggregator");
  }

  function test_reverts_whenCallerNotOwner() public {
    BaseScript.Call[] memory calls = script.callsFor(address(resolver), RESOLVER_FEE_AGG);
    vm.prank(address(0xBAD));
    (bool ok,) = calls[0].to.call(calls[0].data); // onlyOwner
    assertFalse(ok, "non-owner should not set resolver fee aggregator");
  }

  function test_readsResolverFeeAggregator_fromExampleRoles() public view {
    Types.RolesConfig memory roles = ConfigLib.readRolesByPath("config/roles/sepolia.example.json");
    // The resolver fee aggregator is DISTINCT from the verifier's (see roles example).
    assertEq(roles.resolver.feeAggregator, address(0x2000000000000000000000000000000000000005), "resolver fee agg");
    assertTrue(roles.resolver.feeAggregator != roles.verifier.feeAggregator, "two distinct fee destinations");
  }
}
