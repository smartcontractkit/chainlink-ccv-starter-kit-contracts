// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UpdateStorageLocations} from "../../script/configure/UpdateStorageLocations.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";

/// @notice Exercises the UpdateStorageLocations builder against the real audited
///         CommitteeVerifier. The fixture makes this test the storageLocationsAdmin
///         (the constructor sets it to the deployer), so the call is authorized here.
contract UpdateStorageLocationsTest is CommitteeVerifierSetup {
  UpdateStorageLocations internal script;

  function setUp() public override {
    super.setUp();
    script = new UpdateStorageLocations();
  }

  function _updateStorageLocations(
    string[] memory locations
  ) internal returns (bool ok) {
    BaseScript.Call memory call = script.callFor(address(verifier), locations);
    assertEq(call.to, address(verifier), "target is verifier");
    (ok,) = call.to.call(call.data); // msg.sender == storageLocationsAdmin (this test)
  }

  function _twoLocations(
    string memory a,
    string memory b
  ) internal pure returns (string[] memory arr) {
    arr = new string[](2);
    arr[0] = a;
    arr[1] = b;
  }

  function _oneLocation(
    string memory a
  ) internal pure returns (string[] memory arr) {
    arr = new string[](1);
    arr[0] = a;
  }

  function test_precondition_thisTestIsStorageLocationsAdmin() public view {
    assertEq(verifier.getStorageLocationsAdmin(), address(this), "test is the storageLocationsAdmin");
  }

  function test_callFor_setsStorageLocations() public {
    assertTrue(
      _updateStorageLocations(_twoLocations("https://agg-a.example/ccv", "https://agg-b.example/ccv")), "update failed"
    );

    string[] memory got = verifier.getStorageLocations();
    assertEq(got.length, 2, "two locations");
    assertEq(got[0], "https://agg-a.example/ccv");
    assertEq(got[1], "https://agg-b.example/ccv");
  }

  function test_fullReplacement_overwritesPrevious() public {
    assertTrue(_updateStorageLocations(_oneLocation("https://old.example/ccv")), "first set failed");
    assertTrue(
      _updateStorageLocations(_twoLocations("https://new-1.example/ccv", "https://new-2.example/ccv")), "replace failed"
    );

    string[] memory got = verifier.getStorageLocations();
    assertEq(got.length, 2, "replaced, not appended");
    assertEq(got[0], "https://new-1.example/ccv");
  }

  function test_emptyLocationsAllowed() public {
    assertTrue(_updateStorageLocations(_oneLocation("https://x.example/ccv")), "set failed");
    assertTrue(_updateStorageLocations(new string[](0)), "clear failed");
    assertEq(verifier.getStorageLocations().length, 0, "cleared");
  }

  function test_reverts_whenCallerNotStorageLocationsAdmin() public {
    BaseScript.Call memory call = script.callFor(address(verifier), _oneLocation("https://x.example/ccv"));
    // Even the owner cannot call this if they are not the storageLocationsAdmin.
    vm.prank(address(0xBAD));
    (bool ok,) = call.to.call(call.data); // OnlyCallableByStorageLocationsAdmin
    assertFalse(ok, "non-admin should not update storage locations");
  }
}
