// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DriftCheck} from "../../script/governance/DriftCheck.s.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {
  SignatureQuorumValidator
} from "@chainlink/contracts-ccip/contracts/ccvs/components/SignatureQuorumValidator.sol";
import {IRouter} from "@chainlink/contracts-ccip/contracts/interfaces/IRouter.sol";

/// @title DriftCheckTest
/// @notice Exercises the full-config comparison against the real
///         audited contracts, wired to a known-good state in `setUp`, then perturbs
///         ONE dimension per test.
/// @dev Everything goes through `checkAll` / the per-area seams rather than `run()`,
///      which reads `config/` from disk. That keeps the assertions on the comparison
///      logic instead of on fixture files, and matches the seam pattern the configure
///      scripts already use.
contract DriftCheckTest is CommitteeVerifierSetup {
  DriftCheck internal script;

  string internal constant ALIAS = "local_chain";
  string internal constant REMOTE_ALIAS = "remote_chain";
  uint64 internal constant LOCAL_SELECTOR = 1111;
  uint64 internal constant REMOTE_SELECTOR = 2222;

  address internal constant ROUTER = address(0x9001);
  address internal constant RESOLVER_FEE_AGGREGATOR = address(0xFEE2);
  uint16 internal constant FEE_USD_CENTS = 25;
  uint32 internal constant GAS_FOR_VERIFICATION = 200_000;
  uint16 internal constant PAYLOAD_SIZE_BYTES = 96;
  uint8 internal constant THRESHOLD = 2;
  string internal constant STORAGE_LOCATION = "https://aggregator.example/ccv";

  address[] internal signers;

  function setUp() public virtual override {
    super.setUp();
    script = new DriftCheck();

    signers.push(address(0xA1));
    signers.push(address(0xA2));
    signers.push(address(0xA3));

    // ---- wire the live contracts to match the config the helpers below build ----

    // Inbound leg (this chain is the DEST of remote_chain -> local_chain).
    SignatureQuorumValidator.SignatureConfig[] memory sigConfigs = new SignatureQuorumValidator.SignatureConfig[](1);
    sigConfigs[0] = SignatureQuorumValidator.SignatureConfig({
      sourceChainSelector: REMOTE_SELECTOR, threshold: THRESHOLD, signers: signers
    });
    verifier.applySignatureConfigs(new uint64[](0), sigConfigs);

    // Outbound leg (this chain is the SOURCE of local_chain -> remote_chain).
    BaseVerifier.RemoteChainConfigArgs[] memory remotes = new BaseVerifier.RemoteChainConfigArgs[](1);
    remotes[0] = BaseVerifier.RemoteChainConfigArgs({
      router: IRouter(ROUTER),
      remoteChainSelector: REMOTE_SELECTOR,
      allowlistEnabled: false,
      feeUSDCents: FEE_USD_CENTS,
      gasForVerification: GAS_FOR_VERIFICATION,
      payloadSizeBytes: PAYLOAD_SIZE_BYTES
    });
    verifier.applyRemoteChainConfigUpdates(remotes);

    // Resolver: inbound keyed by this chain's versionTag, outbound keyed by dest selector.
    VersionedVerifierResolver.InboundImplementationArgs[] memory inbound =
      new VersionedVerifierResolver.InboundImplementationArgs[](1);
    inbound[0] =
      VersionedVerifierResolver.InboundImplementationArgs({version: VERSION_TAG, verifier: address(verifier)});
    resolver.applyInboundImplementationUpdates(inbound);

    VersionedVerifierResolver.OutboundImplementationArgs[] memory outbound =
      new VersionedVerifierResolver.OutboundImplementationArgs[](1);
    outbound[0] = VersionedVerifierResolver.OutboundImplementationArgs({
      destChainSelector: REMOTE_SELECTOR, verifier: address(verifier)
    });
    resolver.applyOutboundImplementationUpdates(outbound);

    resolver.setFeeAggregator(RESOLVER_FEE_AGGREGATOR);
  }

  // ===========================================================================
  //  clean baseline
  // ===========================================================================

  function test_clean_reportsNoDrift() public view {
    assertEq(script.checkAll(_deployment(), _chainConfig(), _roles(), _lanes()), 0, "clean state must report no drift");
  }

  // ===========================================================================
  //  roles
  // ===========================================================================

  function test_drift_verifierOwner() public view {
    Types.RolesConfig memory roles = _roles();
    roles.verifier.owner = address(0xBAD);
    assertEq(script.checkRoles(_deployment(), roles), 1, "verifier owner mismatch");
  }

  function test_drift_resolverOwner() public view {
    Types.RolesConfig memory roles = _roles();
    roles.resolver.owner = address(0xBAD);
    assertEq(script.checkRoles(_deployment(), roles), 1, "resolver owner mismatch");
  }

  function test_drift_storageLocationsAdmin() public view {
    Types.RolesConfig memory roles = _roles();
    roles.verifier.storageLocationsAdmin = address(0xBAD);
    assertEq(script.checkRoles(_deployment(), roles), 1, "storageLocationsAdmin mismatch");
  }

  function test_drift_dynamicConfigRoles() public view {
    Types.RolesConfig memory roles = _roles();
    roles.verifier.feeAggregator = address(0xBAD);
    roles.verifier.allowlistAdmin = address(0xBAD);
    assertEq(script.checkRoles(_deployment(), roles), 2, "both DynamicConfig roles counted separately");
  }

  function test_drift_factoryOwner() public view {
    Types.RolesConfig memory roles = _roles();
    roles.factoryOwner = address(0xBAD);
    assertEq(script.checkRoles(_deployment(), roles), 1, "factory owner mismatch");
  }

  /// @dev The two fee aggregators are distinct values on distinct contracts; a stale
  ///      config that reuses one for both must be caught, not silently accepted.
  function test_drift_feeAggregatorsAreNotInterchangeable() public view {
    Types.RolesConfig memory roles = _roles();
    roles.resolver.feeAggregator = FEE_AGGREGATOR; // the VERIFIER's aggregator
    assertEq(script.checkRoles(_deployment(), roles), 1, "resolver aggregator must be compared independently");
  }

  /// @dev An unrecorded factory is skipped rather than compared against zero.
  function test_absentFactory_isNotDrift() public view {
    Types.Deployment memory deployment = _deployment();
    deployment.factory = address(0);
    assertEq(script.checkRoles(deployment, _roles()), 0, "absent factory must not count as drift");
  }

  // ===========================================================================
  //  chain-scoped verifier config
  // ===========================================================================

  function test_drift_versionTag() public view {
    Types.ChainConfig memory chainConfig = _chainConfig();
    chainConfig.versionTag = 0xDEADBEEF;
    assertEq(script.checkVerifierConfig(_deployment(), chainConfig), 1, "immutable versionTag mismatch");
  }

  function test_drift_finalityConfig() public view {
    Types.ChainConfig memory chainConfig = _chainConfig();
    chainConfig.finalityConfig = 0x00000009;
    assertEq(script.checkVerifierConfig(_deployment(), chainConfig), 1, "allowedFinalityConfig mismatch");
  }

  function test_drift_storageLocations_content() public view {
    Types.ChainConfig memory chainConfig = _chainConfig();
    chainConfig.storageLocations[0] = "https://elsewhere.example/ccv";
    assertEq(script.checkVerifierConfig(_deployment(), chainConfig), 1, "storage location content mismatch");
  }

  function test_drift_storageLocations_count() public view {
    Types.ChainConfig memory chainConfig = _chainConfig();
    chainConfig.storageLocations = new string[](2);
    chainConfig.storageLocations[0] = STORAGE_LOCATION;
    chainConfig.storageLocations[1] = "https://second.example/ccv";
    assertEq(script.checkVerifierConfig(_deployment(), chainConfig), 1, "storage location count mismatch");
  }

  // ===========================================================================
  //  lanes — direction mapping
  // ===========================================================================

  function test_drift_signerThreshold() public view {
    Types.LaneConfig[] memory lanes = _lanes();
    lanes[1].signatureConfig.threshold = THRESHOLD + 1;
    assertEq(script.checkLanes(_deployment(), _chainConfig(), lanes), 1, "threshold mismatch");
  }

  function test_drift_signerSet() public view {
    Types.LaneConfig[] memory lanes = _lanes();
    lanes[1].signatureConfig.signers[0] = address(0xBAD);
    assertEq(script.checkLanes(_deployment(), _chainConfig(), lanes), 1, "signer set mismatch");
  }

  /// @dev The on-chain set is an EnumerableSet, so iteration order carries no meaning.
  ///      Re-ordering the config must NOT be reported as drift, or every CI run would
  ///      cry wolf after a cosmetic config edit.
  function test_signerSet_comparedAsSetNotList() public view {
    Types.LaneConfig[] memory lanes = _lanes();
    address[] memory reversed = new address[](3);
    reversed[0] = signers[2];
    reversed[1] = signers[1];
    reversed[2] = signers[0];
    lanes[1].signatureConfig.signers = reversed;
    assertEq(script.checkLanes(_deployment(), _chainConfig(), lanes), 0, "signer order must be irrelevant");
  }

  /// @dev Direction lock-in: the signer set for a lane lives on the DEST chain's
  ///      verifier. A lane where this chain is the SOURCE must not be signature-checked
  ///      here, even though the lane declares a signer set.
  function test_direction_signatureConfigCheckedOnDestOnly() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](1);
    lanes[0] = _outboundLane();
    // This lane's signer set is never applied to the local verifier; if the check ran
    // on the source side it would see an empty set and report drift.
    lanes[0].signatureConfig.signers = signers;
    lanes[0].signatureConfig.threshold = THRESHOLD;
    assertEq(script.checkLanes(_deployment(), _chainConfig(), lanes), 0, "source side must not check signatures");
  }

  /// @dev The mirror of the above: remote chain config lives on the SOURCE verifier,
  ///      so a lane where this chain is the DEST must not be remote-config-checked.
  function test_direction_remoteChainConfigCheckedOnSourceOnly() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](1);
    lanes[0] = _inboundLane();
    lanes[0].remote.router = address(0xBAD);
    lanes[0].remote.gasForVerification = 1;
    assertEq(script.checkLanes(_deployment(), _chainConfig(), lanes), 0, "dest side must not check remote config");
  }

  function test_drift_remoteChainConfig_router() public view {
    Types.LaneConfig[] memory lanes = _lanes();
    lanes[0].remote.router = address(0xBAD);
    assertEq(script.checkLanes(_deployment(), _chainConfig(), lanes), 1, "router mismatch");
  }

  function test_drift_remoteChainConfig_everyField() public view {
    Types.LaneConfig[] memory lanes = _lanes();
    lanes[0].remote.router = address(0xBAD);
    lanes[0].allowlist.allowlistEnabled = true;
    lanes[0].remote.feeUSDCents = FEE_USD_CENTS + 1;
    lanes[0].remote.gasForVerification = GAS_FOR_VERIFICATION + 1;
    lanes[0].remote.payloadSizeBytes = PAYLOAD_SIZE_BYTES + 1;
    assertEq(script.checkLanes(_deployment(), _chainConfig(), lanes), 5, "each remote field counted separately");
  }

  /// @dev An unconfigured lane reads back as a zeroed struct, not a revert. That must
  ///      surface as drift on every field rather than passing silently.
  function test_drift_unconfiguredOutboundLane() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](1);
    lanes[0] = _outboundLane();
    lanes[0].dest.chainSelector = 9999; // never configured on the verifier
    assertGt(script.checkLanes(_deployment(), _chainConfig(), lanes), 0, "unconfigured lane must be drift");
  }

  // ===========================================================================
  //  resolver implementation maps
  // ===========================================================================

  function test_drift_inboundImplementation_missing() public {
    VersionedVerifierResolver fresh = new VersionedVerifierResolver();
    Types.Deployment memory deployment = _deployment();
    deployment.resolver = address(fresh);
    // No inbound registration and no outbound registration on the fresh resolver:
    // one inbound miss + one outbound miss for the single source-side lane.
    assertEq(script.checkResolverImplementations(deployment, _chainConfig(), _lanes()), 2, "both maps must be flagged");
  }

  function test_drift_outboundImplementation_pointsElsewhere() public {
    VersionedVerifierResolver.OutboundImplementationArgs[] memory outbound =
      new VersionedVerifierResolver.OutboundImplementationArgs[](1);
    outbound[0] = VersionedVerifierResolver.OutboundImplementationArgs({
      destChainSelector: REMOTE_SELECTOR, verifier: address(0xBAD)
    });
    resolver.applyOutboundImplementationUpdates(outbound);

    assertEq(
      script.checkResolverImplementations(_deployment(), _chainConfig(), _lanes()),
      1,
      "outbound impl must point at the local verifier"
    );
  }

  /// @dev Direction lock-in for the resolver: outbound entries are only expected for
  ///      lanes whose SOURCE is this chain.
  function test_direction_outboundImplementationCheckedOnSourceOnly() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](1);
    lanes[0] = _inboundLane();
    assertEq(
      script.checkResolverImplementations(_deployment(), _chainConfig(), lanes),
      0,
      "dest-side lane must not expect an outbound entry"
    );
  }

  // ===========================================================================
  //  reachability is an environment problem, not drift
  // ===========================================================================

  function test_unreachableVerifier_revertsWithoutMarker() public {
    Types.Deployment memory deployment = _deployment();
    deployment.verifier = address(0xC0DE1E55); // recorded, but no code here
    vm.expectRevert("DriftCheck: no code at recorded verifier (wrong --rpc-url?)");
    script.checkAll(deployment, _chainConfig(), _roles(), _lanes());
  }

  function test_unreachableResolver_revertsWithoutMarker() public {
    Types.Deployment memory deployment = _deployment();
    deployment.resolver = address(0xC0DE1E55);
    vm.expectRevert("DriftCheck: no code at recorded resolver (wrong --rpc-url?)");
    script.checkAll(deployment, _chainConfig(), _roles(), _lanes());
  }

  // ===========================================================================
  //  aggregate
  // ===========================================================================

  /// @dev Drift is counted, not short-circuited: an operator needs the full list in
  ///      one run, not a fix-one-rerun loop.
  function test_multipleDrifts_areAllCounted() public view {
    Types.RolesConfig memory roles = _roles();
    roles.verifier.owner = address(0xBAD);
    roles.resolver.feeAggregator = address(0xBAD);

    Types.ChainConfig memory chainConfig = _chainConfig();
    chainConfig.finalityConfig = 0x00000009;

    Types.LaneConfig[] memory lanes = _lanes();
    lanes[0].remote.router = address(0xBAD);

    assertEq(script.checkAll(_deployment(), chainConfig, roles, lanes), 4, "every mismatch reported in one pass");
  }

  // ===========================================================================
  //  fixture builders
  // ===========================================================================

  function _deployment() internal view returns (Types.Deployment memory deployment) {
    deployment.aliasName = ALIAS;
    deployment.factory = address(factory);
    deployment.resolver = address(resolver);
    deployment.verifier = address(verifier);
  }

  function _chainConfig() internal pure returns (Types.ChainConfig memory chainConfig) {
    chainConfig.aliasName = ALIAS;
    chainConfig.chainSelector = LOCAL_SELECTOR;
    chainConfig.rmn = RMN;
    chainConfig.versionTag = VERSION_TAG;
    chainConfig.finalityConfig = 0x00000000; // constructor default; never set in the fixture
    chainConfig.storageLocations = new string[](1);
    chainConfig.storageLocations[0] = STORAGE_LOCATION;
    chainConfig.resolverSalt = RESOLVER_SALT;
  }

  function _roles() internal view returns (Types.RolesConfig memory roles) {
    roles.aliasName = ALIAS;
    roles.verifier.owner = address(this);
    roles.verifier.storageLocationsAdmin = address(this); // constructor sets deployer
    roles.verifier.allowlistAdmin = address(this);
    roles.verifier.feeAggregator = FEE_AGGREGATOR;
    roles.resolver.owner = address(this);
    roles.resolver.feeAggregator = RESOLVER_FEE_AGGREGATOR;
    roles.factoryOwner = address(this);
  }

  /// @dev Index 0 is the SOURCE-side lane, index 1 is the DEST-side lane. Tests index
  ///      deliberately so a direction regression shows up as a failing assertion.
  function _lanes() internal view returns (Types.LaneConfig[] memory lanes) {
    lanes = new Types.LaneConfig[](2);
    lanes[0] = _outboundLane();
    lanes[1] = _inboundLane();
  }

  function _outboundLane() internal view returns (Types.LaneConfig memory lane) {
    lane.name = "local_to_remote";
    lane.source = Types.LaneEndpoint({aliasName: ALIAS, chainSelector: LOCAL_SELECTOR});
    lane.dest = Types.LaneEndpoint({aliasName: REMOTE_ALIAS, chainSelector: REMOTE_SELECTOR});
    lane.remote = Types.RemoteChainConfig({
      router: ROUTER,
      feeUSDCents: FEE_USD_CENTS,
      gasForVerification: GAS_FOR_VERIFICATION,
      payloadSizeBytes: PAYLOAD_SIZE_BYTES
    });
    // Signature config for this lane is applied on the DEST chain, not here.
    lane.signatureConfig.threshold = THRESHOLD;
    lane.signatureConfig.signers = signers;
  }

  function _inboundLane() internal view returns (Types.LaneConfig memory lane) {
    lane.name = "remote_to_local";
    lane.source = Types.LaneEndpoint({aliasName: REMOTE_ALIAS, chainSelector: REMOTE_SELECTOR});
    lane.dest = Types.LaneEndpoint({aliasName: ALIAS, chainSelector: LOCAL_SELECTOR});
    lane.signatureConfig.threshold = THRESHOLD;
    lane.signatureConfig.signers = signers;
    // Remote chain config for this lane is applied on the SOURCE chain, not here.
  }
}
