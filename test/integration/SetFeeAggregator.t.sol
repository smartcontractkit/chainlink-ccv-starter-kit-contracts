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
    BaseScript.Call memory call = script.callFor(address(resolver), feeAggregator);
    assertEq(call.to, address(resolver), "target is resolver");
    (ok,) = call.to.call(call.data); // msg.sender == owner (this test)
  }

  function test_callFor_setsResolverFeeAggregator() public {
    assertTrue(_applyFeeAggregator(RESOLVER_FEE_AGG), "apply failed");
    assertEq(resolver.getFeeAggregator(), RESOLVER_FEE_AGG, "resolver feeAggregator");
  }

  function test_reverts_whenCallerNotOwner() public {
    BaseScript.Call memory call = script.callFor(address(resolver), RESOLVER_FEE_AGG);
    vm.prank(address(0xBAD));
    (bool ok,) = call.to.call(call.data); // onlyOwner
    assertFalse(ok, "non-owner should not set resolver fee aggregator");
  }

  function test_readsResolverFeeAggregator_fromExampleRoles() public view {
    Types.OperatorConfig memory operator = ConfigLib.readOperatorByPath("config/operator/chains/sepolia.example.json");
    // The resolver fee aggregator is DISTINCT from the verifier's (see roles example).
    assertEq(
      operator.resolver.roles.feeAggregator, address(0x2000000000000000000000000000000000000005), "resolver fee agg"
    );
    assertTrue(
      operator.resolver.roles.feeAggregator != ConfigLib.verifierConfigByTag(operator, VERSION_TAG).roles.feeAggregator,
      "two distinct fee destinations"
    );
  }
}
