// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CREATE2Factory} from "@chainlink/contracts-ccip/contracts/CREATE2Factory.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";

/// @title CommitteeVerifierSetup
/// @notice Integration test FIXTURE, modelled on Chainlink's own `*Setup.t.sol`
///         (chainlink-ccip: chains/evm/contracts/test/ccvs/{CommitteeVerifier,
///         VersionedVerifierResolver}/). Deploys the real audited contracts locally
///         and wires the minimal happy path, so deploy/config scripts can be
///         exercised against a faithful environment. Inherit this in concrete tests.
///
/// @dev Deployment mirrors the production flow: factory (EOA/allowlisted) ->
///      resolver via CREATE2 -> verifier via plain CREATE.
abstract contract CommitteeVerifierSetup is Test {
  CREATE2Factory internal factory;
  VersionedVerifierResolver internal resolver;
  CommitteeVerifier internal verifier;

  // A non-zero placeholder RMN. The constructor only requires non-zero; verification
  // paths that actually call RMN should replace this with a mock/real RMN.
  address internal constant RMN = address(0x000000000000000000000000000000000000dEaD);
  bytes4 internal constant VERSION_TAG = 0x00010001;
  bytes32 internal constant RESOLVER_SALT = bytes32(uint256(1));
  address internal constant FEE_AGGREGATOR = address(0xFEE);

  function setUp() public virtual {
    // 1) Factory — deployer (this test) is allowlisted so it can drive CREATE2.
    address[] memory allowList = new address[](1);
    allowList[0] = address(this);
    factory = new CREATE2Factory(allowList);

    // 2) Resolver via CREATE2 (no constructor args). Transfer ownership to this test
    //    and accept it, so onlyOwner resolver calls can be exercised.
    bytes memory resolverCode = type(VersionedVerifierResolver).creationCode;
    resolver =
      VersionedVerifierResolver(factory.createAndTransferOwnership(resolverCode, RESOLVER_SALT, address(this)));
    resolver.acceptOwnership();

    // 3) Verifier via plain CREATE with constructor args.
    string[] memory storageLocations = new string[](1);
    storageLocations[0] = "https://aggregator.example/ccv";
    CommitteeVerifier.DynamicConfig memory dyn =
      CommitteeVerifier.DynamicConfig({feeAggregator: FEE_AGGREGATOR, allowlistAdmin: address(this)});
    verifier = new CommitteeVerifier(dyn, storageLocations, RMN, VERSION_TAG);
  }

  /// @notice Sanity check that the fixture wired up as expected.
  function test_setup_wiring() public view {
    assertEq(resolver.owner(), address(this), "resolver owner");
    assertEq(verifier.owner(), address(this), "verifier owner");
    assertEq(verifier.getStorageLocations().length, 1, "storage locations");
    assertEq(verifier.typeAndVersion(), "CommitteeVerifier 2.0.0", "verifier version");
    assertEq(resolver.typeAndVersion(), "VersionedVerifierResolver 2.0.0", "resolver version");
  }
}
