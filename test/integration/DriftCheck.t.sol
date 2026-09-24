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
    assertEq(script.checkAll(_deployment(), _roles(), _lanes()), 0, "clean state must report no drift");
  }

  // ===========================================================================
  //  roles
  // ===========================================================================

  function test_drift_verifierOwner() public view {
    Types.OperatorConfig memory operator = _roles();
    operator.verifiers[0].roles.owner = address(0xBAD);
    assertEq(script.checkRoles(_deployment(), operator), 1, "verifier owner mismatch");
  }

  function test_drift_resolverOwner() public view {
    Types.OperatorConfig memory operator = _roles();
    operator.resolver.roles.owner = address(0xBAD);
    assertEq(script.checkRoles(_deployment(), operator), 1, "resolver owner mismatch");
  }

  function test_drift_storageLocationsAdmin() public view {
    Types.OperatorConfig memory operator = _roles();
    operator.verifiers[0].roles.storageLocationsAdmin = address(0xBAD);
    assertEq(script.checkRoles(_deployment(), operator), 1, "storageLocationsAdmin mismatch");
  }

  function test_drift_dynamicConfigRoles() public view {
    Types.OperatorConfig memory operator = _roles();
    operator.verifiers[0].roles.feeAggregator = address(0xBAD);
    operator.verifiers[0].roles.allowlistAdmin = address(0xBAD);
    assertEq(script.checkRoles(_deployment(), operator), 2, "both DynamicConfig roles counted separately");
  }

  function test_drift_factoryOwner() public view {
    Types.OperatorConfig memory operator = _roles();
    operator.factory.roles.owner = address(0xBAD);
    assertEq(script.checkRoles(_deployment(), operator), 1, "factory owner mismatch");
  }

  function test_drift_factoryAllowlist_notInConfig() public view {
    Types.OperatorConfig memory operator = _roles();
    operator.factory.roles.allowlist = new address[](0);
    assertEq(script.checkRoles(_deployment(), operator), 1, "account on-chain but not in config");
  }

  function test_drift_factoryAllowlist_missingOnChain() public view {
    Types.OperatorConfig memory operator = _roles();
    operator.factory.roles.allowlist[0] = address(0xBAD);
    assertEq(script.checkRoles(_deployment(), operator), 1, "config account never allowlisted on-chain");
  }

  function test_factoryAllowlist_orderIsNotDrift() public {
    address replacement = address(0xD3B7);
    address[] memory adds = new address[](1);
    adds[0] = replacement;
    factory.applyAllowListUpdates(new address[](0), adds);

    Types.OperatorConfig memory operator = _roles();
    operator.factory.roles.allowlist = new address[](2);
    operator.factory.roles.allowlist[0] = replacement;
    operator.factory.roles.allowlist[1] = address(this);

    assertEq(script.checkRoles(_deployment(), operator), 0, "same set, different order");
  }

  /// @dev The two fee aggregators are distinct values on distinct contracts; a stale
  ///      config that reuses one for both must be caught, not silently accepted.
  function test_drift_feeAggregatorsAreNotInterchangeable() public view {
    Types.OperatorConfig memory operator = _roles();
    operator.resolver.roles.feeAggregator = FEE_AGGREGATOR; // the VERIFIER's aggregator
    assertEq(script.checkRoles(_deployment(), operator), 1, "resolver aggregator must be compared independently");
  }

  /// @dev An unrecorded factory is skipped rather than compared against zero.
  function test_absentFactory_isNotDrift() public view {
    Types.Deployment memory deployment = _deployment();
    deployment.factory = address(0);
    assertEq(script.checkRoles(deployment, _roles()), 0, "absent factory must not count as drift");
  }

  /// @dev Roles are per verifier: a recorded verifier with no roles entry has no
  ///      machine-checkable intent, which is drift, not a skip.
  function test_drift_recordedVerifierWithoutRolesEntry() public view {
    Types.OperatorConfig memory operator = _roles();
    operator.verifiers[0].versionTag = VERSION_TAG_V2; // entry names a tag the record does not carry
    assertEq(script.checkRoles(_deployment(), operator), 1, "missing roles entry is one drift");
  }

  // ===========================================================================
  //  chain-scoped verifier config
  // ===========================================================================

  function test_drift_versionTag() public view {
    Types.Deployment memory deployment = _deployment();
    deployment.verifiers[0].versionTag = 0xDEADBEEF; // record disagrees with the immutable on-chain tag
    assertEq(script.checkVerifierConfig(deployment, _roles()), 1, "immutable versionTag mismatch");
  }

  function test_drift_allowedFinality() public view {
    Types.OperatorConfig memory operator = _roles();
    operator.verifiers[0].allowedFinality.minBlockDepth = 9;
    assertEq(script.checkVerifierConfig(_deployment(), operator), 1, "allowedFinality mismatch");
  }

  function test_drift_storageLocations_content() public view {
    Types.OperatorConfig memory operator = _roles();
    operator.verifiers[0].storageLocations[0] = "https://elsewhere.example/ccv";
    assertEq(script.checkVerifierConfig(_deployment(), operator), 1, "storage location content mismatch");
  }

  function test_drift_storageLocations_count() public view {
    Types.OperatorConfig memory operator = _roles();
    operator.verifiers[0].storageLocations = new string[](2);
    operator.verifiers[0].storageLocations[0] = STORAGE_LOCATION;
    operator.verifiers[0].storageLocations[1] = "https://second.example/ccv";
    assertEq(script.checkVerifierConfig(_deployment(), operator), 1, "storage location count mismatch");
  }

  // ===========================================================================
  //  lanes — direction mapping
  // ===========================================================================

  function test_drift_signerThreshold() public view {
    Types.LaneCommittee[] memory lanes = _lanes();
    lanes[1].committee.threshold = THRESHOLD + 1;
    assertEq(script.checkLanes(_deployment(), _roles(), lanes), 1, "threshold mismatch");
  }

  function test_drift_signerSet() public view {
    Types.LaneCommittee[] memory lanes = _lanes();
    lanes[1].committee.signers[0] = address(0xBAD);
    assertEq(script.checkLanes(_deployment(), _roles(), lanes), 1, "signer set mismatch");
  }

  /// @dev The on-chain set is an EnumerableSet, so iteration order carries no meaning.
  ///      Re-ordering the config must NOT be reported as drift, or every CI run would
  ///      cry wolf after a cosmetic config edit.
  function test_signerSet_comparedAsSetNotList() public view {
    Types.LaneCommittee[] memory lanes = _lanes();
    address[] memory reversed = new address[](3);
    reversed[0] = signers[2];
    reversed[1] = signers[1];
    reversed[2] = signers[0];
    lanes[1].committee.signers = reversed;
    assertEq(script.checkLanes(_deployment(), _roles(), lanes), 0, "signer order must be irrelevant");
  }

  /// @dev Direction lock-in: the signer set for a lane lives on the DEST chain's
  ///      verifier. A lane where this chain is the SOURCE must not be signature-checked
  ///      here, even though the lane declares a signer set.
  function test_direction_signatureConfigCheckedOnDestOnly() public view {
    Types.LaneCommittee[] memory lanes = new Types.LaneCommittee[](1);
    lanes[0] = _outboundLane();
    // This lane's signer set is never applied to the local verifier; if the check ran
    // on the source side it would see an empty set and report drift.
    lanes[0].committee.signers = signers;
    lanes[0].committee.threshold = THRESHOLD;
    assertEq(script.checkLanes(_deployment(), _roles(), lanes), 0, "source side must not check signatures");
  }

  /// @dev The mirror of the above: remote chain config lives on the SOURCE verifier,
  ///      so a lane where this chain is the DEST must not be remote-config-checked.
  function test_direction_remoteChainConfigCheckedOnSourceOnly() public view {
    Types.LaneCommittee[] memory lanes = new Types.LaneCommittee[](1);
    lanes[0] = _inboundLane();
    lanes[0].lane.remote.router = address(0xBAD);
    lanes[0].lane.remote.gasForVerification = 1;
    assertEq(script.checkLanes(_deployment(), _roles(), lanes), 0, "dest side must not check remote config");
  }

  function test_drift_remoteChainConfig_router() public view {
    Types.LaneCommittee[] memory lanes = _lanes();
    lanes[0].lane.remote.router = address(0xBAD);
    assertEq(script.checkLanes(_deployment(), _roles(), lanes), 1, "router mismatch");
  }

  function test_drift_remoteChainConfig_everyField() public view {
    Types.LaneCommittee[] memory lanes = _lanes();
    lanes[0].lane.remote.router = address(0xBAD);
    lanes[0].lane.allowlist.allowlistEnabled = true;
    lanes[0].lane.remote.feeUSDCents = FEE_USD_CENTS + 1;
    lanes[0].lane.remote.gasForVerification = GAS_FOR_VERIFICATION + 1;
    lanes[0].lane.remote.payloadSizeBytes = PAYLOAD_SIZE_BYTES + 1;
    assertEq(script.checkLanes(_deployment(), _roles(), lanes), 5, "each remote field counted separately");
  }

  function _seedAllowlist(
    bool enabled,
    address[] memory added
  ) internal {
    BaseVerifier.AllowlistConfigArgs[] memory args = new BaseVerifier.AllowlistConfigArgs[](1);
    args[0] = BaseVerifier.AllowlistConfigArgs({
      destChainSelector: REMOTE_SELECTOR,
      allowlistEnabled: enabled,
      addedAllowlistedSenders: added,
      removedAllowlistedSenders: new address[](0)
    });
    verifier.applyAllowlistUpdates(args);
  }

  /// @dev `allowedSenders` is the desired full set, so membership is compared both ways,
  ///      as one drift item per lane like the signer set.
  function test_drift_allowlist_senderOnChainNotInConfig() public {
    address[] memory onChain = new address[](1);
    onChain[0] = address(0xA9);
    _seedAllowlist(true, onChain);

    Types.LaneCommittee[] memory lanes = _lanes();
    lanes[0].lane.allowlist.allowlistEnabled = true; // flag agrees; only membership differs
    assertEq(script.checkLanes(_deployment(), _roles(), lanes), 1, "undeclared sender is drift");
  }

  function test_drift_allowlist_senderInConfigMissingOnChain() public {
    _seedAllowlist(true, new address[](0));

    Types.LaneCommittee[] memory lanes = _lanes();
    lanes[0].lane.allowlist.allowlistEnabled = true;
    lanes[0].lane.allowlist.allowedSenders = new address[](1);
    lanes[0].lane.allowlist.allowedSenders[0] = address(0xA9);
    assertEq(script.checkLanes(_deployment(), _roles(), lanes), 1, "declared sender never added is drift");
  }

  function test_allowlist_senderOrderIsNotDrift() public {
    address[] memory onChain = new address[](2);
    onChain[0] = address(0xA8);
    onChain[1] = address(0xA9);
    _seedAllowlist(true, onChain);

    Types.LaneCommittee[] memory lanes = _lanes();
    lanes[0].lane.allowlist.allowlistEnabled = true;
    lanes[0].lane.allowlist.allowedSenders = new address[](2);
    lanes[0].lane.allowlist.allowedSenders[0] = address(0xA9);
    lanes[0].lane.allowlist.allowedSenders[1] = address(0xA8);
    assertEq(script.checkLanes(_deployment(), _roles(), lanes), 0, "same set, different order");
  }

  /// @dev An unconfigured lane reads back as a zeroed struct, not a revert. That must
  ///      surface as drift on every field rather than passing silently.
  function test_drift_unconfiguredOutboundLane() public view {
    Types.LaneCommittee[] memory lanes = new Types.LaneCommittee[](1);
    lanes[0] = _outboundLane();
    lanes[0].lane.dest.chainSelector = 9999; // never configured on the verifier
    assertGt(script.checkLanes(_deployment(), _roles(), lanes), 0, "unconfigured lane must be drift");
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
    assertEq(script.checkResolverImplementations(deployment, _roles(), _lanes()), 2, "both maps must be flagged");
  }

  function test_drift_outboundImplementation_pointsElsewhere() public {
    VersionedVerifierResolver.OutboundImplementationArgs[] memory outbound =
      new VersionedVerifierResolver.OutboundImplementationArgs[](1);
    outbound[0] = VersionedVerifierResolver.OutboundImplementationArgs({
      destChainSelector: REMOTE_SELECTOR, verifier: address(0xBAD)
    });
    resolver.applyOutboundImplementationUpdates(outbound);

    assertEq(
      script.checkResolverImplementations(_deployment(), _roles(), _lanes()),
      1,
      "outbound impl must point at the local verifier"
    );
  }

  /// @dev Direction lock-in for the resolver: outbound entries are only expected for
  ///      lanes whose SOURCE is this chain. With only the dest-side lane declared, the
  ///      single drift is the setUp-wired outbound entry no lane declares any more
  ///      (closed world), NOT a missing entry for the dest-side lane.
  function test_direction_outboundImplementationCheckedOnSourceOnly() public view {
    Types.LaneCommittee[] memory lanes = new Types.LaneCommittee[](1);
    lanes[0] = _inboundLane();
    assertEq(
      script.checkResolverImplementations(_deployment(), _roles(), lanes),
      1,
      "dest-side lane expects no outbound entry; only the undeclared on-chain entry is flagged"
    );
  }

  /// @dev CLOSED WORLD, inbound: an on-chain registration whose tag is not in the
  ///      deployment record is attack surface and must be drift.
  function test_drift_unknownInboundRegistration() public {
    VersionedVerifierResolver.InboundImplementationArgs[] memory rogue =
      new VersionedVerifierResolver.InboundImplementationArgs[](1);
    rogue[0] = VersionedVerifierResolver.InboundImplementationArgs({version: 0xDEADBEEF, verifier: address(0xBAD)});
    resolver.applyInboundImplementationUpdates(rogue);

    assertEq(
      script.checkResolverImplementations(_deployment(), _roles(), _lanes()),
      1,
      "unknown registered inbound verifier must be drift"
    );
  }

  /// @dev CLOSED WORLD, inbound: a recorded verifier the resolver does not serve is
  ///      drift (its in-flight messages would stop verifying).
  function test_drift_recordedTagNotRegisteredInbound() public {
    _deploySecondVerifier();
    Types.Deployment memory deployment = _deployment();
    deployment.verifiers = new Types.VerifierDeployment[](2);
    deployment.verifiers[0].versionTag = VERSION_TAG;
    deployment.verifiers[0].addr = address(verifier);
    deployment.verifiers[1].versionTag = VERSION_TAG_V2;
    deployment.verifiers[1].addr = address(verifierV2);
    assertEq(
      script.checkResolverImplementations(deployment, _roles(), _lanes()),
      1,
      "recorded-but-unregistered verifier must be drift"
    );
  }

  /// @dev CLOSED WORLD, outbound: an on-chain outbound entry no lane declares is drift.
  function test_drift_outboundEntryNoLaneDeclares() public view {
    assertEq(
      script.checkResolverImplementations(_deployment(), _roles(), new Types.LaneCommittee[](0)),
      1,
      "the setUp-wired outbound entry is undeclared once no lane names it"
    );
  }

  /// @dev A lane pinned to a versionTag that was never deployed here cannot be checked;
  ///      it must be reported as drift, not revert the whole run.
  function test_drift_lanePinnedToUnrecordedTag() public view {
    Types.LaneCommittee[] memory lanes = new Types.LaneCommittee[](1);
    lanes[0] = _outboundLane();
    lanes[0].lane.versionTag = VERSION_TAG_V2; // never deployed in this fixture
    // One drift from the resolver map (no verifier for the tag) is counted; the wired
    // outbound entry stays declared by the lane's dest selector, so no undeclared hit.
    assertEq(script.checkResolverImplementations(_deployment(), _roles(), lanes), 1, "resolver tier");
    assertEq(script.checkLanes(_deployment(), _roles(), lanes), 1, "lane tier");
  }

  /// @dev Two verifiers live at once, each fully wired, must be CLEAN — the whole
  ///      point of the multi-verifier record.
  function test_twoVerifiers_cleanState() public {
    _deploySecondVerifier();

    // Register the second verifier inbound (upgrade ceremony step one).
    VersionedVerifierResolver.InboundImplementationArgs[] memory inbound =
      new VersionedVerifierResolver.InboundImplementationArgs[](1);
    inbound[0] =
      VersionedVerifierResolver.InboundImplementationArgs({version: VERSION_TAG_V2, verifier: address(verifierV2)});
    resolver.applyInboundImplementationUpdates(inbound);

    Types.Deployment memory deployment = _deployment();
    deployment.verifiers = new Types.VerifierDeployment[](2);
    deployment.verifiers[0].versionTag = VERSION_TAG;
    deployment.verifiers[0].addr = address(verifier);
    deployment.verifiers[1].versionTag = VERSION_TAG_V2;
    deployment.verifiers[1].addr = address(verifierV2);
    assertEq(script.checkAll(deployment, _rolesBothVerifiers(), _lanes()), 0, "two live verifiers, no drift");
  }

  // ===========================================================================
  //  reachability is an environment problem, not drift
  // ===========================================================================

  function test_unreachableVerifier_revertsWithoutMarker() public {
    Types.Deployment memory deployment = _deployment();
    deployment.verifiers[0].addr = address(0xC0DE1E55); // recorded, but no code here
    vm.expectRevert("DriftCheck: no code at recorded verifier for versionTag 0x00010001 (wrong --rpc-url?)");
    // called for its expected revert; the return is irrelevant
    // forge-lint: disable-next-line(unused-return)
    script.checkAll(deployment, _roles(), _lanes());
  }

  function test_unreachableResolver_revertsWithoutMarker() public {
    Types.Deployment memory deployment = _deployment();
    deployment.resolver = address(0xC0DE1E55);
    vm.expectRevert("DriftCheck: no code at recorded resolver (wrong --rpc-url?)");
    // called for its expected revert; the return is irrelevant
    // forge-lint: disable-next-line(unused-return)
    script.checkAll(deployment, _roles(), _lanes());
  }

  // ===========================================================================
  //  aggregate
  // ===========================================================================

  /// @dev Drift is counted, not short-circuited: an operator needs the full list in
  ///      one run, not a fix-one-rerun loop.
  function test_multipleDrifts_areAllCounted() public view {
    Types.OperatorConfig memory operator = _roles();
    operator.verifiers[0].roles.owner = address(0xBAD);
    operator.resolver.roles.feeAggregator = address(0xBAD);
    operator.verifiers[0].allowedFinality.minBlockDepth = 9;

    Types.LaneCommittee[] memory lanes = _lanes();
    lanes[0].lane.remote.router = address(0xBAD);

    assertEq(script.checkAll(_deployment(), operator, lanes), 4, "every mismatch reported in one pass");
  }

  // ===========================================================================
  //  fixture builders
  // ===========================================================================

  function _deployment() internal view returns (Types.Deployment memory deployment) {
    deployment.aliasName = ALIAS;
    deployment.factory = address(factory);
    deployment.resolver = address(resolver);
    deployment.verifiers = _verifiersOf(address(verifier));
  }

  function _roles() internal view returns (Types.OperatorConfig memory operator) {
    operator.aliasName = ALIAS;
    // the fixture entry mirrors what setUp() deployed: constructor finality default,
    // the same storage locations, and the deployer in every role
    operator.verifiers = _singleVerifierConfig(_fixtureVerifierConfig(VERSION_TAG));
    operator.resolver.roles.owner = address(this);
    operator.resolver.roles.feeAggregator = RESOLVER_FEE_AGGREGATOR;
    operator.factory.roles.owner = address(this);
    // setUp allowlists the deployer so it can drive CREATE2; the clean state says so.
    operator.factory.roles.allowlist = new address[](1);
    operator.factory.roles.allowlist[0] = address(this);
  }

  function _rolesBothVerifiers() internal view returns (Types.OperatorConfig memory operator) {
    operator = _roles();
    operator.verifiers = new Types.VerifierConfig[](2);
    operator.verifiers[0] = _fixtureVerifierConfig(VERSION_TAG);
    operator.verifiers[1] = _fixtureVerifierConfig(VERSION_TAG_V2);
  }

  /// @dev Index 0 is the SOURCE-side lane, index 1 is the DEST-side lane. Tests index
  ///      deliberately so a direction regression shows up as a failing assertion.
  function _lanes() internal view returns (Types.LaneCommittee[] memory lanes) {
    lanes = new Types.LaneCommittee[](2);
    lanes[0] = _outboundLane();
    lanes[1] = _inboundLane();
  }

  function _outboundLane() internal view returns (Types.LaneCommittee memory entry) {
    entry.lane.name = "local_to_remote";
    entry.lane.source = Types.LaneEndpoint({aliasName: ALIAS, chainSelector: LOCAL_SELECTOR});
    entry.lane.dest = Types.LaneEndpoint({aliasName: REMOTE_ALIAS, chainSelector: REMOTE_SELECTOR});
    entry.lane.versionTag = VERSION_TAG;
    entry.lane.remote = Types.RemoteChainConfig({
      router: ROUTER,
      feeUSDCents: FEE_USD_CENTS,
      gasForVerification: GAS_FOR_VERIFICATION,
      payloadSizeBytes: PAYLOAD_SIZE_BYTES
    });
    // Signature config for this lane is applied on the DEST chain, not here.
    entry.committee.threshold = THRESHOLD;
    entry.committee.signers = signers;
  }

  function _inboundLane() internal view returns (Types.LaneCommittee memory entry) {
    entry.lane.name = "remote_to_local";
    entry.lane.source = Types.LaneEndpoint({aliasName: REMOTE_ALIAS, chainSelector: REMOTE_SELECTOR});
    entry.lane.dest = Types.LaneEndpoint({aliasName: ALIAS, chainSelector: LOCAL_SELECTOR});
    entry.lane.versionTag = VERSION_TAG;
    entry.committee.threshold = THRESHOLD;
    entry.committee.signers = signers;
    // Remote chain config for this lane is applied on the SOURCE chain, not here.
  }
}
