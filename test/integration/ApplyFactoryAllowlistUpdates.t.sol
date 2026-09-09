// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ApplyFactoryAllowlistUpdates} from "../../script/configure/ApplyFactoryAllowlistUpdates.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";

/// @notice Exercises the factory-allowlist diff and builder against the real audited
///         CREATE2Factory. The fixture makes this test the factory owner AND the
///         constructor-allowlisted deployer — the exact state the cleanup targets.
contract ApplyFactoryAllowlistUpdatesTest is CommitteeVerifierSetup {
  ApplyFactoryAllowlistUpdates internal script;

  address internal constant REPLACEMENT = address(0xD3B7);

  function setUp() public override {
    super.setUp();
    script = new ApplyFactoryAllowlistUpdates();
  }

  function _apply(
    address[] memory removes,
    address[] memory adds
  ) internal returns (bool ok) {
    BaseScript.Call memory call = script.callFor(address(factory), removes, adds);
    assertEq(call.to, address(factory), "target is factory");
    (ok,) = call.to.call(call.data); // msg.sender == factory owner (this test)
  }

  function _oneAccount(
    address a
  ) internal pure returns (address[] memory arr) {
    arr = new address[](1);
    arr[0] = a;
  }

  function test_precondition_deployerIsAllowlisted() public view {
    address[] memory current = factory.getAllowList();
    assertEq(current.length, 1, "constructor allowlists exactly the deployer");
    assertEq(current[0], address(this), "the deployer (this test)");
    assertEq(factory.owner(), address(this), "test is the factory owner");
  }

  function test_diff_matchingSet_isEmpty() public view {
    (address[] memory removes, address[] memory adds) = script.diff(address(factory), _oneAccount(address(this)));
    assertEq(removes.length, 0, "nothing to remove");
    assertEq(adds.length, 0, "nothing to add");
  }

  function test_diff_emptyDesired_removesTheDeployer() public view {
    (address[] memory removes, address[] memory adds) = script.diff(address(factory), new address[](0));
    assertEq(removes.length, 1, "one removal");
    assertEq(removes[0], address(this), "the lingering deployer");
    assertEq(adds.length, 0, "nothing to add");
  }

  function test_diff_replacementAccount_isAnAdd() public view {
    address[] memory desired = new address[](2);
    desired[0] = address(this);
    desired[1] = REPLACEMENT;
    (address[] memory removes, address[] memory adds) = script.diff(address(factory), desired);
    assertEq(removes.length, 0, "deployer kept");
    assertEq(adds.length, 1, "one addition");
    assertEq(adds[0], REPLACEMENT, "the replacement account");
  }

  function test_callFor_removesTheDeployer() public {
    assertTrue(_apply(_oneAccount(address(this)), new address[](0)), "removal failed");
    assertEq(factory.getAllowList().length, 0, "deployer pruned; getAllowList is empty");
  }

  /// @dev The replacement-deployer procedure the natspec documents: add, use, remove.
  function test_replacementAccount_roundTrip() public {
    assertTrue(_apply(new address[](0), _oneAccount(REPLACEMENT)), "add failed");
    assertEq(factory.getAllowList().length, 2, "deployer + replacement");

    assertTrue(_apply(_oneAccount(REPLACEMENT), new address[](0)), "remove failed");
    (address[] memory removes, address[] memory adds) = script.diff(address(factory), _oneAccount(address(this)));
    assertEq(removes.length + adds.length, 0, "back to the original set");
  }

  function test_reverts_whenCallerNotOwner() public {
    BaseScript.Call memory call = script.callFor(address(factory), _oneAccount(address(this)), new address[](0));
    // Allowlist membership grants createAndCall, NOT allowlist management.
    vm.prank(address(0xBAD));
    (bool ok,) = call.to.call(call.data); // Ownable: caller is not the owner
    assertFalse(ok, "non-owner must not update the allowlist");
    assertEq(factory.getAllowList().length, 1, "allowlist untouched");
  }
}
