// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ApplyInboundImplementationUpdates} from "../../script/configure/ApplyInboundImplementationUpdates.s.sol";
import {ApplyOutboundImplementationUpdates} from "../../script/configure/ApplyOutboundImplementationUpdates.s.sol";
import {ApplyRemoteChainConfigUpdates} from "../../script/configure/ApplyRemoteChainConfigUpdates.s.sol";
import {ApplySignatureConfigs} from "../../script/configure/ApplySignatureConfigs.s.sol";
import {SetFeeAggregator} from "../../script/configure/SetFeeAggregator.s.sol";
import {DeployVerifier} from "../../script/deploy/DeployVerifier.s.sol";
import {DriftCheck} from "../../script/governance/DriftCheck.s.sol";
import {LaneParityCheck} from "../../script/governance/LaneParityCheck.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {Types} from "../../src/lib/Types.sol";
import {MockRMN} from "../mocks/MockRMN.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {MessageV1Codec} from "@chainlink/contracts-ccip/contracts/libraries/MessageV1Codec.sol";
import {MockCCIPRouter} from "@chainlink/contracts-ccip/contracts/test/mocks/MockRouter.sol";

/// @title DeployAndConfigureTest
/// @notice Composition tests for the deploy + configure flow. The per-script suites each
///         cover one operation in isolation; these assert the operations compose into a
///         working lane, and that the emergency lever actually stops traffic.
/// @dev No fork, no RPC, so this suite runs in the PR gate. `test_endToEndAcceptance` is
///      the one test that will need one; it stays skipped until its fixtures (token,
///      token pools, CCV-requiring receiver) land from Chainlink Labs (open point 12).
contract DeployAndConfigureTest is CommitteeVerifierSetup {
  uint64 internal constant SOURCE_SELECTOR = 1111;
  uint64 internal constant DEST_SELECTOR = 2222;
  uint64 internal constant OTHER_SELECTOR = 3333;
  address internal constant SENDER = address(0x5E11);
  address internal constant RESOLVER_FEE_AGGREGATOR = address(0xFEE2);
  uint16 internal constant FEE_USD_CENTS = 25;
  uint32 internal constant GAS_FOR_VERIFICATION = 200_000;
  uint16 internal constant PAYLOAD_SIZE_BYTES = 96;
  uint8 internal constant THRESHOLD = 7;

  MockCCIPRouter internal router;
  MockRMN internal rmn;
  CommitteeVerifier internal pausableVerifier;
  address internal onRamp;

  ApplySignatureConfigs internal applySig;
  ApplyRemoteChainConfigUpdates internal applyRemote;
  ApplyInboundImplementationUpdates internal applyInbound;
  ApplyOutboundImplementationUpdates internal applyOutbound;
  SetFeeAggregator internal setFeeAggregator;
  DriftCheck internal driftCheck;

  address[] internal signers;

  function setUp() public override {
    super.setUp();

    // Committee policy: not 1-of-1, threshold above 2/3 (7-of-10).
    for (uint160 i = 1; i <= 10; ++i) {
      signers.push(address(0x1000 + i));
    }

    applySig = new ApplySignatureConfigs();
    applyRemote = new ApplyRemoteChainConfigUpdates();
    applyInbound = new ApplyInboundImplementationUpdates();
    applyOutbound = new ApplyOutboundImplementationUpdates();
    setFeeAggregator = new SetFeeAggregator();
    driftCheck = new DriftCheck();

    router = new MockCCIPRouter();
    onRamp = router.getOnRamp(DEST_SELECTOR);
    rmn = new MockRMN();

    // A second verifier wired to the mock RMN. `i_rmn` is immutable and the fixture's
    // placeholder RMN has no code, so reaching `forwardToVerifier` needs its own deploy.
    string[] memory storageLocations = new string[](1);
    storageLocations[0] = "https://aggregator.example/ccv";
    pausableVerifier = new CommitteeVerifier(
      CommitteeVerifier.DynamicConfig({feeAggregator: FEE_AGGREGATOR, allowlistAdmin: address(this)}),
      storageLocations,
      address(rmn),
      VERSION_TAG
    );
  }

  // ===========================================================================
  //  configure composition
  // ===========================================================================

  /// @notice Drive every configure operation for one lane through the scripts' own call
  ///         builders, then assert `DriftCheck` reports the result clean.
  /// @dev Each script is verified in isolation elsewhere; nothing else checks that
  ///      applying all of them yields a state the governance tooling agrees with. A
  ///      direction bug in any one script, or a disagreement between a configure script
  ///      and `DriftCheck`, fails here.
  function test_configureLaneThroughScripts_thenDriftCheckIsClean() public {
    Types.LaneConfig memory lane = _lane();

    _exec(applySig.callsFor(address(verifier), new uint64[](0), applySig.toSignatureConfig(lane)));
    _exec(applyRemote.callsFor(address(verifier), applyRemote.toRemoteChainConfigArgs(lane)));
    _exec(applyInbound.callsFor(address(resolver), applyInbound.toInboundArgs(VERSION_TAG, address(verifier))));
    _exec(applyOutbound.callsFor(address(resolver), _outboundArgs(lane)));
    _exec(setFeeAggregator.callsFor(address(resolver), RESOLVER_FEE_AGGREGATOR));

    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](1);
    lanes[0] = lane;

    assertEq(
      driftCheck.checkAll(_deployment(), _chainConfig(), _roles(), lanes),
      0,
      "a lane configured through the scripts must not read back as drift"
    );
  }

  /// @notice Once a lane is configured, every script that can skip work must agree it is
  ///         current — the same state `DriftCheck` reports clean.
  /// @dev Ties the skip logic to the drift definition, which nothing else does. A script
  ///      comparing FEWER fields than `DriftCheck` drops a real change from the batch
  ///      while drift keeps reporting it; comparing MORE restages a lane that never
  ///      changes. Both are silent: re-writing a matching value never reverts.
  function test_afterConfiguring_everyScriptReportsTheLaneCurrent() public {
    Types.LaneConfig memory lane = _lane();

    assertFalse(applySig.isCurrent(address(verifier), lane), "nothing applied yet");
    assertFalse(applyRemote.isCurrent(address(verifier), lane), "nothing applied yet");
    assertFalse(
      applyOutbound.isCurrent(address(resolver), lane.dest.chainSelector, address(verifier)), "nothing applied yet"
    );

    _exec(applySig.callsFor(address(verifier), new uint64[](0), applySig.toSignatureConfig(lane)));
    _exec(applyRemote.callsFor(address(verifier), applyRemote.toRemoteChainConfigArgs(lane)));
    _exec(applyOutbound.callsFor(address(resolver), _outboundArgs(lane)));

    assertTrue(applySig.isCurrent(address(verifier), lane), "signature config re-reads as current");
    assertTrue(applyRemote.isCurrent(address(verifier), lane), "remote chain config re-reads as current");
    assertTrue(
      applyOutbound.isCurrent(address(resolver), lane.dest.chainSelector, address(verifier)),
      "outbound implementation re-reads as current"
    );
  }

  /// @dev The lane is both source and dest of itself, with DIFFERENT selectors per side,
  ///      so one chain exercises both directions. Guards against a configure script and
  ///      `DriftCheck` agreeing on the wrong side: the signer set is keyed by SOURCE
  ///      selector, the remote config by DEST selector.
  function test_configureLane_appliesEachSideToItsOwnKey() public {
    Types.LaneConfig memory lane = _lane();
    _exec(applySig.callsFor(address(verifier), new uint64[](0), applySig.toSignatureConfig(lane)));
    _exec(applyRemote.callsFor(address(verifier), applyRemote.toRemoteChainConfigArgs(lane)));

    (address[] memory onChainSigners, uint8 threshold) = verifier.getSignatureConfig(SOURCE_SELECTOR);
    assertEq(threshold, THRESHOLD, "signer set landed under the SOURCE selector");
    assertEq(onChainSigners.length, signers.length, "full signer set");

    // the other return values are deliberately ignored
    // forge-lint: disable-next-line(unused-return)
    (BaseVerifier.RemoteChainConfigArgs memory remote,) = verifier.getRemoteChainConfig(DEST_SELECTOR);
    assertEq(address(remote.router), address(router), "remote config landed under the DEST selector");

    // the other return values are deliberately ignored
    // forge-lint: disable-next-line(unused-return)
    (, uint8 wrongWay) = verifier.getSignatureConfig(DEST_SELECTOR);
    assertEq(wrongWay, 0, "no signer set under the dest selector");
  }

  // ===========================================================================
  //  deployment record — one entry per verifier, append-only
  // ===========================================================================

  function test_recordVerifier_appendsEachTag() public {
    Types.Deployment memory deployment;
    deployment.aliasName = "local";

    DeployVerifierHarness harness = new DeployVerifierHarness();
    deployment = harness.record(deployment, VERSION_TAG, address(verifier), false);
    deployment = harness.record(deployment, VERSION_TAG_V2, address(0xBEEF), false);

    assertEq(deployment.verifiers.length, 2, "one entry per verifier");
    assertEq(deployment.verifiers[0].versionTag, VERSION_TAG, "verifier 1 kept");
    assertEq(deployment.verifiers[0].addr, address(verifier));
    assertEq(deployment.verifiers[1].versionTag, VERSION_TAG_V2, "verifier 2 appended");
    assertEq(deployment.verifiers[1].addr, address(0xBEEF));
  }

  /// @dev A re-deploy under an existing tag would silently orphan the previous verifier;
  ///      it must refuse unless explicitly waived.
  function test_recordVerifier_duplicateTagRevertsWithoutWaiver() public {
    Types.Deployment memory deployment;
    deployment.aliasName = "local";

    DeployVerifierHarness harness = new DeployVerifierHarness();
    deployment = harness.record(deployment, VERSION_TAG, address(verifier), false);

    vm.expectRevert(
      "DeployVerifier: versionTag 0x00010001 already recorded for local"
      " - pick a new tag, or set ALLOW_TAG_REPLACE=true to replace a deploy nothing references yet"
    );
    // the expected revert is the assertion; the return is irrelevant
    // forge-lint: disable-next-line(unused-return)
    harness.record(deployment, VERSION_TAG, address(0xBEEF), false);
  }

  function test_recordVerifier_waiverReplacesTheEntryInPlace() public {
    Types.Deployment memory deployment;
    deployment.aliasName = "local";

    DeployVerifierHarness harness = new DeployVerifierHarness();
    deployment = harness.record(deployment, VERSION_TAG, address(verifier), false);
    deployment = harness.record(deployment, VERSION_TAG, address(0xBEEF), true);

    assertEq(deployment.verifiers.length, 1, "replaced, not appended");
    assertEq(deployment.verifiers[0].addr, address(0xBEEF), "new address under the same tag");
  }

  // ===========================================================================
  //  upgrade ceremony — the multi-verifier acceptance test
  // ===========================================================================

  /// @notice Wire verifier 1, deploy verifier 2, pin the lane to it, wire, and cut
  ///         over. Verifier 1 keeps verifying in-flight messages (its inbound entry
  ///         survives) while verifier 2 takes new traffic (outbound flipped), and both
  ///         governance checks read the two-verifier state as clean.
  function test_upgradeCeremony_gen2TakesTrafficWhileGen1KeepsVerifying() public {
    // ---- verifier 1 fully wired ----
    Types.LaneConfig memory lane = _lane();
    _exec(applySig.callsFor(address(verifier), new uint64[](0), applySig.toSignatureConfig(lane)));
    _exec(applyRemote.callsFor(address(verifier), applyRemote.toRemoteChainConfigArgs(lane)));
    _exec(applyInbound.callsFor(address(resolver), applyInbound.toInboundArgs(VERSION_TAG, address(verifier))));
    _exec(applyOutbound.callsFor(address(resolver), _outboundArgs(lane)));
    _exec(setFeeAggregator.callsFor(address(resolver), RESOLVER_FEE_AGGREGATOR));

    // ---- deploy verifier 2 and pin the lane to it ----
    _deploySecondVerifier();
    lane.versionTag = VERSION_TAG_V2;

    // Ceremony order: dest side first (inbound + signatures), then source side, then cutover.
    _exec(applyInbound.callsFor(address(resolver), applyInbound.toInboundArgs(VERSION_TAG_V2, address(verifierV2))));
    _exec(applySig.callsFor(address(verifierV2), new uint64[](0), applySig.toSignatureConfig(lane)));
    _exec(applyRemote.callsFor(address(verifierV2), applyRemote.toRemoteChainConfigArgs(lane)));
    VersionedVerifierResolver.OutboundImplementationArgs[] memory flip =
      new VersionedVerifierResolver.OutboundImplementationArgs[](1);
    flip[0] = VersionedVerifierResolver.OutboundImplementationArgs({
      destChainSelector: lane.dest.chainSelector, verifier: address(verifierV2)
    });
    _exec(applyOutbound.callsFor(address(resolver), flip));

    // ---- flip-then-drain: old tag keeps resolving, new tag takes traffic ----
    assertEq(
      resolver.getInboundImplementation(abi.encodePacked(VERSION_TAG)),
      address(verifier),
      "verifier 1 inbound entry survives the cutover (in-flight messages still verify)"
    );
    assertEq(
      resolver.getInboundImplementation(abi.encodePacked(VERSION_TAG_V2)),
      address(verifierV2),
      "verifier 2 registered inbound"
    );
    assertEq(
      resolver.getOutboundImplementation(lane.dest.chainSelector, ""),
      address(verifierV2),
      "outbound flipped to verifier 2"
    );

    // ---- both governance checks agree the two-verifier state is clean ----
    Types.Deployment memory deployment = _deployment();
    deployment.verifiers = new Types.VerifierDeployment[](2);
    deployment.verifiers[0].versionTag = VERSION_TAG;
    deployment.verifiers[0].addr = address(verifier);
    deployment.verifiers[1].versionTag = VERSION_TAG_V2;
    deployment.verifiers[1].addr = address(verifierV2);
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](1);
    lanes[0] = lane;
    assertEq(driftCheck.checkAll(deployment, _chainConfig(), _rolesBothVerifiers(), lanes), 0, "DriftCheck clean");

    LaneParityCheck parity = new LaneParityCheck();
    Types.ChainConfig memory destChain = _chainConfig();
    destChain.chainSelector = DEST_SELECTOR;
    assertEq(
      parity.checkConfigParity(lane, _chainConfig(), destChain, deployment, deployment), 0, "config parity clean"
    );
    assertEq(parity.checkSourceSide(lane, deployment), 0, "source side clean");
    assertEq(parity.checkDestSide(lane, lane.versionTag, deployment), 0, "dest side clean");
  }

  // ===========================================================================
  //  emergency lever
  // ===========================================================================

  /// @notice `router = 0` is the ONLY outbound kill switch — there is no pause function
  ///         and no inbound halt.
  function test_outboundPauseLever_haltsForwardToVerifier() public {
    _exec(applyRemote.callsFor(address(pausableVerifier), applyRemote.toRemoteChainConfigArgs(_lane())));

    vm.prank(onRamp);
    bytes memory ret = pausableVerifier.forwardToVerifier(_message(DEST_SELECTOR), bytes32(0), address(0), 0, "");
    assertEq(ret, abi.encodePacked(VERSION_TAG), "with a router set, the verifier accepts and returns its tag");

    // Zero the router, preserving every other field. gasForVerification must stay
    // non-zero even when pausing: BaseVerifier reverts DestGasCannotBeZero regardless.
    Types.LaneConfig memory paused = _lane();
    paused.remote.router = address(0);
    _exec(applyRemote.callsFor(address(pausableVerifier), applyRemote.toRemoteChainConfigArgs(paused)));

    vm.prank(onRamp);
    vm.expectRevert(abi.encodeWithSelector(BaseVerifier.RemoteChainNotSupported.selector, DEST_SELECTOR));
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    pausableVerifier.forwardToVerifier(_message(DEST_SELECTOR), bytes32(0), address(0), 0, "");
  }

  /// @dev The lever is per-destination, not global: pausing one lane must not affect
  ///      another. Nothing else in the suite pins this.
  function test_outboundPauseLever_isPerDestination() public {
    Types.LaneConfig memory other = _lane();
    other.dest.chainSelector = OTHER_SELECTOR;

    _exec(applyRemote.callsFor(address(pausableVerifier), applyRemote.toRemoteChainConfigArgs(_lane())));
    _exec(applyRemote.callsFor(address(pausableVerifier), applyRemote.toRemoteChainConfigArgs(other)));

    Types.LaneConfig memory paused = _lane();
    paused.remote.router = address(0);
    _exec(applyRemote.callsFor(address(pausableVerifier), applyRemote.toRemoteChainConfigArgs(paused)));

    vm.prank(onRamp);
    bytes memory ret = pausableVerifier.forwardToVerifier(_message(OTHER_SELECTOR), bytes32(0), address(0), 0, "");
    assertEq(ret, abi.encodePacked(VERSION_TAG), "the un-paused destination still forwards");
  }

  /// @dev An RMN curse is a separate, Chainlink-operated halt that precedes our checks.
  function test_rmnCurse_haltsBeforeRouterCheck() public {
    _exec(applyRemote.callsFor(address(pausableVerifier), applyRemote.toRemoteChainConfigArgs(_lane())));
    rmn.setCursed(true);

    vm.prank(onRamp);
    vm.expectRevert(abi.encodeWithSelector(BaseVerifier.CursedByRMN.selector, DEST_SELECTOR));
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    pausableVerifier.forwardToVerifier(_message(DEST_SELECTOR), bytes32(0), address(0), 0, "");
  }

  /// @dev Only the router-resolved OnRamp may forward, so a stale or wrong caller is
  ///      rejected even while the lane is fully configured.
  function test_forwardToVerifier_rejectsNonRampCaller() public {
    _exec(applyRemote.callsFor(address(pausableVerifier), applyRemote.toRemoteChainConfigArgs(_lane())));

    vm.prank(address(0xBAD));
    vm.expectRevert(abi.encodeWithSelector(BaseVerifier.CallerIsNotARampOnRouter.selector, address(0xBAD)));
    // the expected revert is the assertion; the call returns no value
    // forge-lint: disable-next-line(unused-return)
    pausableVerifier.forwardToVerifier(_message(DEST_SELECTOR), bytes32(0), address(0), 0, "");
  }

  // ===========================================================================
  //  end-to-end acceptance — blocked on external fixtures
  // ===========================================================================

  /// @notice Send on the source, verify on the destination, over a real lane.
  function test_endToEndAcceptance() public {
    vm.skip(true);
  }

  // ===========================================================================
  //  fixtures
  // ===========================================================================

  function _lane() internal view returns (Types.LaneConfig memory lane) {
    lane.name = "compose_lane";
    lane.source = Types.LaneEndpoint({aliasName: "local", chainSelector: SOURCE_SELECTOR});
    lane.dest = Types.LaneEndpoint({aliasName: "local", chainSelector: DEST_SELECTOR});
    lane.versionTag = VERSION_TAG;
    lane.signatureConfig.threshold = THRESHOLD;
    lane.signatureConfig.signers = signers;
    lane.remote = Types.RemoteChainConfig({
      router: address(router),
      feeUSDCents: FEE_USD_CENTS,
      gasForVerification: GAS_FOR_VERIFICATION,
      payloadSizeBytes: PAYLOAD_SIZE_BYTES
    });
  }

  function _outboundArgs(
    Types.LaneConfig memory lane
  ) internal view returns (VersionedVerifierResolver.OutboundImplementationArgs[] memory args) {
    args = new VersionedVerifierResolver.OutboundImplementationArgs[](1);
    args[0] = VersionedVerifierResolver.OutboundImplementationArgs({
      destChainSelector: lane.dest.chainSelector, verifier: address(verifier)
    });
  }

  function _message(
    uint64 destSelector
  ) internal pure returns (MessageV1Codec.MessageV1 memory m) {
    m.sourceChainSelector = SOURCE_SELECTOR;
    m.destChainSelector = destSelector;
    m.sender = abi.encode(SENDER);
  }

  function _deployment() internal view returns (Types.Deployment memory deployment) {
    deployment.aliasName = "local";
    deployment.factory = address(factory);
    deployment.resolver = address(resolver);
    deployment.verifiers = _verifiersOf(address(verifier));
  }

  function _chainConfig() internal pure returns (Types.ChainConfig memory chainConfig) {
    chainConfig.aliasName = "local";
    chainConfig.chainSelector = SOURCE_SELECTOR;
    chainConfig.rmn = RMN;
    chainConfig.finalityConfig = 0x00000000;
    chainConfig.storageLocations = new string[](1);
    chainConfig.storageLocations[0] = "https://aggregator.example/ccv";
    chainConfig.resolverSalt = RESOLVER_SALT;
  }

  function _roles() internal view returns (Types.RolesConfig memory roles) {
    roles.aliasName = "local";
    roles.verifiers = _singleVerifierRoles(_fixtureVerifierRoles(VERSION_TAG));
    roles.resolver.owner = address(this);
    roles.resolver.feeAggregator = RESOLVER_FEE_AGGREGATOR;
    roles.factoryOwner = address(this);
    // setUp allowlists the deployer so it can drive CREATE2; the clean state says so.
    roles.factoryAllowlist = new address[](1);
    roles.factoryAllowlist[0] = address(this);
  }

  /// @dev Roles for both verifiers — the ceremony's two-verifier DriftCheck needs an
  ///      entry per recorded tag.
  function _rolesBothVerifiers() internal view returns (Types.RolesConfig memory roles) {
    roles = _roles();
    roles.verifiers = new Types.VerifierRoles[](2);
    roles.verifiers[0] = _fixtureVerifierRoles(VERSION_TAG);
    roles.verifiers[1] = _fixtureVerifierRoles(VERSION_TAG_V2);
  }

  function _exec(
    BaseScript.Call[] memory calls
  ) internal {
    for (uint256 i = 0; i < calls.length; ++i) {
      // a generic executor: the destination is caller-supplied by design
      // forge-lint: disable-next-line(arbitrary-send-eth)
      (bool ok, bytes memory ret) = calls[i].to.call{value: calls[i].value}(calls[i].data);
      if (!ok) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
          revert(add(ret, 0x20), mload(ret))
        }
      }
    }
  }
}

/// @dev Exposes the internal record logic through an external call, so a memory struct
///      round-trips by value and `vm.expectRevert` sees the revert in a CALL.
contract DeployVerifierHarness is DeployVerifier {
  function record(
    Types.Deployment memory deployment,
    bytes4 versionTag,
    address verifier,
    bool allowReplace
  ) external pure returns (Types.Deployment memory) {
    Types.VerifierDeployment memory entry;
    entry.versionTag = versionTag;
    entry.addr = verifier;
    _recordVerifier(deployment, entry, allowReplace);
    return deployment;
  }
}
