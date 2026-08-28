// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {Test} from "forge-std/Test.sol";

/// @title TargetResolutionTest
/// @notice The `"verifier" | "resolver" | "factory"` dispatch shared by the ownership
///         scripts. The factory case completes the transfer `BootstrapFactory` proposes;
///         without it the deployer EOA stays factory owner and keeps control of the
///         CREATE2 allowlist.
/// @dev Address and owner resolution are separate functions so the accept leg needs no
///      roles file: acceptance is authorised by msg.sender, not by config.
contract TargetResolutionTest is Test {
  address internal constant VERIFIER = address(0xD1);
  address internal constant RESOLVER = address(0xD2);
  address internal constant FACTORY = address(0xD3);

  function test_targetAddress_resolvesEachTarget() public pure {
    Types.Deployment memory deployment = _dep();
    assertEq(ConfigLib.targetAddress(deployment, "verifier"), VERIFIER, "verifier");
    assertEq(ConfigLib.targetAddress(deployment, "resolver"), RESOLVER, "resolver");
    assertEq(ConfigLib.targetAddress(deployment, "factory"), FACTORY, "factory");
  }

  function test_targetOwner_resolvesEachTarget() public pure {
    Types.RolesConfig memory roles = _roles();
    assertEq(ConfigLib.targetOwner(roles, "verifier"), address(0xA1), "verifier owner");
    assertEq(ConfigLib.targetOwner(roles, "resolver"), address(0xA2), "resolver owner");
    assertEq(ConfigLib.targetOwner(roles, "factory"), address(0xA3), "factory owner");
  }

  /// @dev Both lookups must accept the same names, or the propose and accept legs of one
  ///      ceremony could address different contracts.
  function test_addressAndOwner_acceptTheSameNames() public pure {
    string[3] memory names = ["verifier", "resolver", "factory"];
    for (uint256 i = 0; i < names.length; ++i) {
      assertTrue(ConfigLib.targetAddress(_dep(), names[i]) != address(0), "address side");
      assertTrue(ConfigLib.targetOwner(_roles(), names[i]) != address(0), "owner side");
    }
  }

  function test_targetAddress_revertsOnUnknownTarget() public {
    vm.expectRevert("ConfigLib: unknown target 'onramp' (expected verifier|resolver|factory)");
    this.callTargetAddress("onramp");
  }

  function test_targetOwner_revertsOnUnknownTarget() public {
    vm.expectRevert("ConfigLib: unknown target 'Verifier' (expected verifier|resolver|factory)");
    this.callTargetOwner("Verifier");
  }

  /// @dev External wrappers: `vm.expectRevert` needs the revert to happen in a CALL, and
  ///      library internal functions inline into this contract.
  function callTargetAddress(
    string calldata target
  ) external pure returns (address) {
    return ConfigLib.targetAddress(_dep(), target);
  }

  function callTargetOwner(
    string calldata target
  ) external pure returns (address) {
    return ConfigLib.targetOwner(_roles(), target);
  }

  function _dep() internal pure returns (Types.Deployment memory deployment) {
    deployment.aliasName = "local";
    deployment.factory = FACTORY;
    deployment.resolver = RESOLVER;
    deployment.verifier = VERIFIER;
  }

  function _roles() internal pure returns (Types.RolesConfig memory roles) {
    roles.aliasName = "local";
    roles.verifier.owner = address(0xA1);
    roles.resolver.owner = address(0xA2);
    roles.factoryOwner = address(0xA3);
  }
}
