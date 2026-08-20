// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CREATE2Factory} from "@chainlink/contracts-ccip/contracts/CREATE2Factory.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Validates the CREATE2 determinism logic DeployResolver relies on: the
///         precomputed address equals the deployed address, redeploying the same
///         salt collides (reverts), and different salts give different addresses.
/// @dev Cross-CHAIN parity (same address on every chain) additionally requires the
///      SAME factory address and identical initcode everywhere — that is asserted
///      operationally by the deploy script + the operator's cross-chain check, and
///      cannot be reproduced inside a single-chain test.
contract DeployResolverDeterminismTest is Test {
  CREATE2Factory internal factory;
  bytes internal resolverCode;

  function setUp() public {
    address[] memory allowList = new address[](1);
    allowList[0] = address(this);
    factory = new CREATE2Factory(allowList);
    resolverCode = type(VersionedVerifierResolver).creationCode;
  }

  function test_deployedAddressEqualsPrecomputed() public {
    bytes32 salt = bytes32(uint256(1));
    address predicted = factory.computeAddress(resolverCode, salt);

    address deployed = factory.createAndTransferOwnership(resolverCode, salt, address(this));
    assertEq(deployed, predicted, "deployed must equal precomputed");

    VersionedVerifierResolver(deployed).acceptOwnership();
    assertEq(VersionedVerifierResolver(deployed).owner(), address(this), "deployer owns after accept");
  }

  function test_redeployingSameSaltReverts() public {
    bytes32 salt = bytes32(uint256(1));
    factory.createAndTransferOwnership(resolverCode, salt, address(this));

    // Same code + salt => same address, which already exists => CREATE2 collision.
    vm.expectRevert();
    factory.createAndTransferOwnership(resolverCode, salt, address(this));
  }

  function test_differentSaltsGiveDifferentAddresses() public view {
    address a = factory.computeAddress(resolverCode, bytes32(uint256(1)));
    address b = factory.computeAddress(resolverCode, bytes32(uint256(2)));
    assertTrue(a != b, "different salts must yield different addresses");
  }
}
