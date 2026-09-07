// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {Test} from "forge-std/Test.sol";

/// @title TargetResolutionTest
/// @notice The `"verifier:<versionTag>" | "resolver" | "factory"` dispatch shared by
///         the ownership scripts. A verifier is ALWAYS addressed by versionTag; a bare
///         "verifier" is rejected outright. The factory case completes the transfer
///         `BootstrapFactory` proposes; without it the deployer EOA stays factory owner
///         and keeps control of the CREATE2 allowlist.
/// @dev Address and owner resolution are separate functions so the accept leg needs no
///      roles file: acceptance is authorised by msg.sender, not by config.
contract TargetResolutionTest is Test {
  address internal constant VERIFIER = address(0xD1);
  address internal constant VERIFIER_V2 = address(0xD4);
  address internal constant RESOLVER = address(0xD2);
  address internal constant FACTORY = address(0xD3);
  bytes4 internal constant TAG = 0x00010001;
  bytes4 internal constant TAG_V2 = 0x00010002;

  function test_targetAddress_resolvesEachTarget() public pure {
    Types.Deployment memory deployment = _dep();
    assertEq(ConfigLib.targetAddress(deployment, "verifier:0x00010001"), VERIFIER, "verifier by tag");
    assertEq(ConfigLib.targetAddress(deployment, "resolver"), RESOLVER, "resolver");
    assertEq(ConfigLib.targetAddress(deployment, "factory"), FACTORY, "factory");
  }

  function test_targetAddress_resolvesVerifierByTag() public pure {
    Types.Deployment memory deployment = _depTwoVerifiers();
    assertEq(ConfigLib.targetAddress(deployment, "verifier:0x00010001"), VERIFIER, "gen 1");
    assertEq(ConfigLib.targetAddress(deployment, "verifier:0x00010002"), VERIFIER_V2, "gen 2");
  }

  /// @dev A bare "verifier" is rejected even with one verifier recorded: several can
  ///      be live at once, and nothing may silently pick one.
  function test_targetAddress_bareVerifierAlwaysReverts() public {
    vm.expectRevert(bytes(ConfigLib.BARE_VERIFIER_TARGET_ERROR));
    this.callTargetAddress("verifier");
  }

  function test_targetAddress_revertsOnUnrecordedTag() public {
    try this.callTargetAddressOn(_dep(), "verifier:0xdeadbeef") {
      fail();
    } catch Error(string memory reason) {
      assertTrue(vm.contains(reason, "deploy that verifier first"), reason);
    }
  }

  function test_targetOwner_resolvesEachTarget() public pure {
    Types.RolesConfig memory roles = _roles();
    assertEq(ConfigLib.targetOwner(roles, "verifier:0x00010001"), address(0xA1), "verifier owner by tag");
    assertEq(ConfigLib.targetOwner(roles, "resolver"), address(0xA2), "resolver owner");
    assertEq(ConfigLib.targetOwner(roles, "factory"), address(0xA3), "factory owner");
  }

  /// @dev Roles are per verifier: the tag form selects THAT verifier's owner.
  function test_targetOwner_resolvesOwnerByTag() public pure {
    assertEq(ConfigLib.targetOwner(_rolesTwoVerifiers(), "verifier:0x00010001"), address(0xA1), "verifier 1 owner");
    assertEq(ConfigLib.targetOwner(_rolesTwoVerifiers(), "verifier:0x00010002"), address(0xA4), "verifier 2 owner");
  }

  /// @dev Same rejection on the owner side, so both legs of a ceremony fail identically.
  function test_targetOwner_bareVerifierAlwaysReverts() public {
    vm.expectRevert(bytes(ConfigLib.BARE_VERIFIER_TARGET_ERROR));
    this.callTargetOwner("verifier");
  }

  function test_targetOwner_revertsOnUndeclaredTag() public {
    try this.callTargetOwnerOn(_roles(), "verifier:0xdeadbeef") {
      fail();
    } catch Error(string memory reason) {
      assertTrue(vm.contains(reason, "declare that verifier's roles first"), reason);
    }
  }

  /// @dev Both lookups must accept the same names, or the propose and accept legs of one
  ///      ceremony could address different contracts.
  function test_addressAndOwner_acceptTheSameNames() public pure {
    string[3] memory names = ["verifier:0x00010001", "resolver", "factory"];
    for (uint256 i = 0; i < names.length; ++i) {
      assertTrue(ConfigLib.targetAddress(_dep(), names[i]) != address(0), "address side");
      assertTrue(ConfigLib.targetOwner(_roles(), names[i]) != address(0), "owner side");
    }
  }

  function test_targetAddress_revertsOnUnknownTarget() public {
    vm.expectRevert("ConfigLib: unknown target 'onramp' (expected verifier:<versionTag>|resolver|factory)");
    this.callTargetAddress("onramp");
  }

  function test_targetOwner_revertsOnUnknownTarget() public {
    vm.expectRevert("ConfigLib: unknown target 'Verifier' (expected verifier:<versionTag>|resolver|factory)");
    this.callTargetOwner("Verifier");
  }

  /// @dev External wrappers: `vm.expectRevert` needs the revert to happen in a CALL, and
  ///      library internal functions inline into this contract.
  function callTargetAddress(
    string calldata target
  ) external pure returns (address) {
    return ConfigLib.targetAddress(_dep(), target);
  }

  function callTargetAddressOn(
    Types.Deployment calldata deployment,
    string calldata target
  ) external pure returns (address) {
    return ConfigLib.targetAddress(deployment, target);
  }

  function callTargetOwner(
    string calldata target
  ) external pure returns (address) {
    return ConfigLib.targetOwner(_roles(), target);
  }

  function callTargetOwnerOn(
    Types.RolesConfig calldata roles,
    string calldata target
  ) external pure returns (address) {
    return ConfigLib.targetOwner(roles, target);
  }

  function _dep() internal pure returns (Types.Deployment memory deployment) {
    deployment.aliasName = "local";
    deployment.factory = FACTORY;
    deployment.resolver = RESOLVER;
    deployment.verifiers = new Types.VerifierDeployment[](1);
    deployment.verifiers[0].versionTag = TAG;
    deployment.verifiers[0].addr = VERIFIER;
  }

  function _depTwoVerifiers() internal pure returns (Types.Deployment memory deployment) {
    deployment = _dep();
    deployment.verifiers = new Types.VerifierDeployment[](2);
    deployment.verifiers[0].versionTag = TAG;
    deployment.verifiers[0].addr = VERIFIER;
    deployment.verifiers[1].versionTag = TAG_V2;
    deployment.verifiers[1].addr = VERIFIER_V2;
  }

  function _roles() internal pure returns (Types.RolesConfig memory roles) {
    roles.aliasName = "local";
    roles.verifiers = new Types.VerifierRoles[](1);
    roles.verifiers[0].versionTag = TAG;
    roles.verifiers[0].owner = address(0xA1);
    roles.resolver.owner = address(0xA2);
    roles.factoryOwner = address(0xA3);
  }

  function _rolesTwoVerifiers() internal pure returns (Types.RolesConfig memory roles) {
    roles = _roles();
    roles.verifiers = new Types.VerifierRoles[](2);
    roles.verifiers[0].versionTag = TAG;
    roles.verifiers[0].owner = address(0xA1);
    roles.verifiers[1].versionTag = TAG_V2;
    roles.verifiers[1].owner = address(0xA4);
  }
}
