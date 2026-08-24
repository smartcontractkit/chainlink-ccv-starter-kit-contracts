// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SetDynamicConfig} from "../../script/configure/SetDynamicConfig.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";

/// @notice Exercises the SetDynamicConfig builder against the real audited
///         CommitteeVerifier (deployed by the fixture, owned by this test).
contract SetDynamicConfigTest is CommitteeVerifierSetup {
  SetDynamicConfig internal script;

  address internal constant FEE_AGG = address(0xFEE1);
  address internal constant ALLOWLIST_ADMIN = address(0xAD);

  function setUp() public override {
    super.setUp();
    script = new SetDynamicConfig();
  }

  function _applyDynamicConfig(
    address feeAggregator,
    address allowlistAdmin
  ) internal returns (bool ok) {
    CommitteeVerifier.DynamicConfig memory dynamicConfig =
      CommitteeVerifier.DynamicConfig({feeAggregator: feeAggregator, allowlistAdmin: allowlistAdmin});
    BaseScript.Call[] memory calls = script.callsFor(address(verifier), dynamicConfig);
    assertEq(calls.length, 1, "one call expected");
    assertEq(calls[0].to, address(verifier), "target is verifier");
    (ok,) = calls[0].to.call(calls[0].data); // msg.sender == owner (this test)
  }

  function test_callsFor_setsDynamicConfig() public {
    assertTrue(_applyDynamicConfig(FEE_AGG, ALLOWLIST_ADMIN), "apply failed");

    CommitteeVerifier.DynamicConfig memory dynamicConfig = verifier.getDynamicConfig();
    assertEq(dynamicConfig.feeAggregator, FEE_AGG, "feeAggregator");
    assertEq(dynamicConfig.allowlistAdmin, ALLOWLIST_ADMIN, "allowlistAdmin");
  }

  function test_reverts_whenCallerNotOwner() public {
    CommitteeVerifier.DynamicConfig memory dynamicConfig =
      CommitteeVerifier.DynamicConfig({feeAggregator: FEE_AGG, allowlistAdmin: ALLOWLIST_ADMIN});
    BaseScript.Call[] memory calls = script.callsFor(address(verifier), dynamicConfig);
    vm.prank(address(0xBAD));
    (bool ok,) = calls[0].to.call(calls[0].data); // onlyOwner
    assertFalse(ok, "non-owner should not set dynamic config");
  }

  function test_toDynamicConfig_fromExampleRoles() public view {
    Types.RolesConfig memory roles = ConfigLib.readRolesByPath("config/roles/sepolia.example.json");
    CommitteeVerifier.DynamicConfig memory dynamicConfig = script.toDynamicConfig(roles);
    assertEq(dynamicConfig.feeAggregator, address(0x2000000000000000000000000000000000000004), "fee agg from roles");
    assertEq(
      dynamicConfig.allowlistAdmin, address(0x2000000000000000000000000000000000000003), "allowlist admin from roles"
    );
  }
}
