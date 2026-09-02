// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Types} from "../../src/lib/Types.sol";
import {CREATE2Factory} from "@chainlink/contracts-ccip/contracts/CREATE2Factory.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {Test} from "forge-std/Test.sol";

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
  bytes4 internal constant VERSION_TAG_V2 = 0x00010002;
  bytes32 internal constant RESOLVER_SALT = bytes32(uint256(1));
  address internal constant FEE_AGGREGATOR = address(0xFEE);

  /// @dev Second verifier, deployed only by tests that call `_deploySecondVerifier()`.
  CommitteeVerifier internal verifierV2;

  function setUp() public virtual {
    // 1) Factory — deployer (this test) is allowlisted so it can drive CREATE2.
    address[] memory allowList = new address[](1);
    allowList[0] = address(this);
    factory = new CREATE2Factory(allowList);

    // 2) Resolver via CREATE2 (no constructor args). Transfer ownership to this test
    //    and accept it, so onlyOwner resolver calls can be exercised.
    bytes memory resolverCode = type(VersionedVerifierResolver).creationCode;
    resolver = VersionedVerifierResolver(factory.createAndTransferOwnership(resolverCode, RESOLVER_SALT, address(this)));
    resolver.acceptOwnership();

    // 3) Verifier via plain CREATE with constructor args.
    string[] memory storageLocations = new string[](1);
    storageLocations[0] = "https://aggregator.example/ccv";
    CommitteeVerifier.DynamicConfig memory dynamicConfig =
      CommitteeVerifier.DynamicConfig({feeAggregator: FEE_AGGREGATOR, allowlistAdmin: address(this)});
    verifier = new CommitteeVerifier(dynamicConfig, storageLocations, RMN, VERSION_TAG);
  }

  /// @notice Opt-in second verifier (tag VERSION_TAG_V2), same roles and locations.
  function _deploySecondVerifier() internal {
    string[] memory storageLocations = new string[](1);
    storageLocations[0] = "https://aggregator.example/ccv";
    CommitteeVerifier.DynamicConfig memory dynamicConfig =
      CommitteeVerifier.DynamicConfig({feeAggregator: FEE_AGGREGATOR, allowlistAdmin: address(this)});
    verifierV2 = new CommitteeVerifier(dynamicConfig, storageLocations, RMN, VERSION_TAG_V2);
  }

  /// @notice Single-entry `verifiers` array for deployment fixtures (tag VERSION_TAG).
  function _verifiersOf(
    address verifierAddr
  ) internal pure returns (Types.VerifierDeployment[] memory list) {
    list = new Types.VerifierDeployment[](1);
    list[0] = Types.VerifierDeployment({versionTag: VERSION_TAG, addr: verifierAddr});
  }

  /// @notice Single-entry verifier-roles array for roles fixtures.
  function _singleVerifierRoles(
    Types.VerifierRoles memory entry
  ) internal pure returns (Types.VerifierRoles[] memory list) {
    list = new Types.VerifierRoles[](1);
    list[0] = entry;
  }

  /// @notice The roles this fixture's constructor arguments produce, for tag `tag`.
  function _fixtureVerifierRoles(
    bytes4 tag
  ) internal view returns (Types.VerifierRoles memory) {
    return Types.VerifierRoles({
      versionTag: tag,
      owner: address(this),
      storageLocationsAdmin: address(this),
      allowlistAdmin: address(this),
      feeAggregator: FEE_AGGREGATOR
    });
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
