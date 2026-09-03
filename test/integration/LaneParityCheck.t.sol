// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaneParityCheck} from "../../script/governance/LaneParityCheck.s.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {
  SignatureQuorumValidator
} from "@chainlink/contracts-ccip/contracts/ccvs/components/SignatureQuorumValidator.sol";
import {IRouter} from "@chainlink/contracts-ccip/contracts/interfaces/IRouter.sol";

/// @title LaneParityCheckTest
/// @notice Cross-chain lane invariants. Tier 1 (`checkConfigParity`) is pure and fully
///         covered here. Tier 2 uses ONE local chain playing both roles: the fixture is
///         wired as source-of-itself and dest-of-itself, which exercises the same reads
///         `run()` performs after each `createSelectFork` without needing two RPCs.
/// @dev What this suite is really protecting: every failure below passes `DriftCheck` on
///      BOTH chains, because each side matches its own config. Only the pairwise
///      comparison catches them.
contract LaneParityCheckTest is CommitteeVerifierSetup {
  LaneParityCheck internal script;

  string internal constant SOURCE_ALIAS = "src_chain";
  string internal constant DEST_ALIAS = "dst_chain";
  uint64 internal constant SOURCE_SELECTOR = 1111;
  uint64 internal constant DEST_SELECTOR = 2222;

  address internal constant ROUTER = address(0x9001);
  uint16 internal constant FEE_USD_CENTS = 25;
  uint32 internal constant GAS_FOR_VERIFICATION = 200_000;
  uint16 internal constant PAYLOAD_SIZE_BYTES = 96;
  uint8 internal constant THRESHOLD = 2;

  address[] internal signers;

  function setUp() public virtual override {
    super.setUp();
    script = new LaneParityCheck();

    signers.push(address(0xA1));
    signers.push(address(0xA2));
    signers.push(address(0xA3));

    // Source side of the lane: outbound impl keyed by DEST selector + remote chain config.
    VersionedVerifierResolver.OutboundImplementationArgs[] memory outbound =
      new VersionedVerifierResolver.OutboundImplementationArgs[](1);
    outbound[0] = VersionedVerifierResolver.OutboundImplementationArgs({
      destChainSelector: DEST_SELECTOR, verifier: address(verifier)
    });
    resolver.applyOutboundImplementationUpdates(outbound);

    BaseVerifier.RemoteChainConfigArgs[] memory remotes = new BaseVerifier.RemoteChainConfigArgs[](1);
    remotes[0] = BaseVerifier.RemoteChainConfigArgs({
      router: IRouter(ROUTER),
      remoteChainSelector: DEST_SELECTOR,
      allowlistEnabled: false,
      feeUSDCents: FEE_USD_CENTS,
      gasForVerification: GAS_FOR_VERIFICATION,
      payloadSizeBytes: PAYLOAD_SIZE_BYTES
    });
    verifier.applyRemoteChainConfigUpdates(remotes);

    // Dest side: inbound impl keyed by the lane's versionTag + signer set
    // keyed by SOURCE selector.
    VersionedVerifierResolver.InboundImplementationArgs[] memory inbound =
      new VersionedVerifierResolver.InboundImplementationArgs[](1);
    inbound[0] =
      VersionedVerifierResolver.InboundImplementationArgs({version: VERSION_TAG, verifier: address(verifier)});
    resolver.applyInboundImplementationUpdates(inbound);

    SignatureQuorumValidator.SignatureConfig[] memory sigConfigs = new SignatureQuorumValidator.SignatureConfig[](1);
    sigConfigs[0] = SignatureQuorumValidator.SignatureConfig({
      sourceChainSelector: SOURCE_SELECTOR, threshold: THRESHOLD, signers: signers
    });
    verifier.applySignatureConfigs(new uint64[](0), sigConfigs);
  }

  // ===========================================================================
  //  TIER 1 — config parity (pure, no chain)
  // ===========================================================================

  function test_configParity_cleanLane() public view {
    assertEq(script.checkConfigParity(_lane(), _srcChain(), _dstChain(), _dep(), _dep()), 0, "clean lane");
  }

  /// @dev The headline invariant, re-keyed to lanes: the lane's verifier must be
  ///      deployed on BOTH endpoints, or every message reverts `InvalidCCVVersion` on
  ///      arrival while `DriftCheck` passes on both sides.
  function test_configParity_laneTagMissingOnDest() public view {
    Types.Deployment memory destDeployment = _dep();
    destDeployment.verifiers[0].versionTag = VERSION_TAG_V2; // dest only has another versionTag
    assertEq(
      script.checkConfigParity(_lane(), _srcChain(), _dstChain(), _dep(), destDeployment),
      1,
      "dest lacks the lane's verifier"
    );
  }

  /// @dev Regression for the DELETED chain-level tag-equality rule: with per-lane tags,
  ///      a lane may pin a DIFFERENT versionTag than other lanes on the same pair, as
  ///      long as both endpoints record it.
  function test_configParity_lanePinnedToSecondVerifierPasses() public {
    _deploySecondVerifier();
    Types.Deployment memory deployment = _dep();
    deployment.verifiers = new Types.VerifierDeployment[](2);
    deployment.verifiers[0].versionTag = VERSION_TAG;
    deployment.verifiers[0].addr = address(verifier);
    deployment.verifiers[1].versionTag = VERSION_TAG_V2;
    deployment.verifiers[1].addr = address(verifierV2);
    Types.LaneConfig memory lane = _lane();
    lane.versionTag = VERSION_TAG_V2;
    assertEq(
      script.checkConfigParity(lane, _srcChain(), _dstChain(), deployment, deployment),
      0,
      "a lane on the second verifier is valid parity"
    );
  }

  /// @dev Apps hardcode one resolver address in `requiredCCVs`; divergence forces
  ///      per-chain integrator config.
  function test_configParity_resolverAddressDivergence() public view {
    Types.Deployment memory destDeployment = _dep();
    destDeployment.resolver = address(0xDEAD);
    assertEq(
      script.checkConfigParity(_lane(), _srcChain(), _dstChain(), _dep(), destDeployment), 1, "resolver divergence"
    );
  }

  function test_configParity_resolverSaltDivergence() public view {
    Types.ChainConfig memory dst = _dstChain();
    dst.resolverSalt = bytes32(uint256(999));
    assertEq(script.checkConfigParity(_lane(), _srcChain(), dst, _dep(), _dep()), 1, "salt divergence");
  }

  /// @dev A stale lane selector registers the outbound impl under a key no message ever
  ///      arrives with. Invisible to any single-chain check.
  function test_configParity_laneSelectorDisagreesWithChainConfig() public view {
    Types.LaneConfig memory lane = _lane();
    lane.dest.chainSelector = 9999;
    assertEq(script.checkConfigParity(lane, _srcChain(), _dstChain(), _dep(), _dep()), 1, "dest selector mismatch");
  }

  function test_configParity_sourceSelectorDisagreesWithChainConfig() public view {
    Types.LaneConfig memory lane = _lane();
    lane.source.chainSelector = 8888;
    assertEq(script.checkConfigParity(lane, _srcChain(), _dstChain(), _dep(), _dep()), 1, "source selector mismatch");
  }

  function test_configParity_zeroGasForVerification() public view {
    Types.LaneConfig memory lane = _lane();
    lane.remote.gasForVerification = 0;
    assertEq(script.checkConfigParity(lane, _srcChain(), _dstChain(), _dep(), _dep()), 1, "zero gas is unconfigurable");
  }

  /// @dev router == 0 is the deliberate outbound kill switch — a valid state, reported
  ///      as a NOTE. It must not fail CI for a lane an operator intentionally paused.
  function test_configParity_zeroRouterIsPausedNotMismatch() public view {
    Types.LaneConfig memory lane = _lane();
    lane.remote.router = address(0);
    assertEq(script.checkConfigParity(lane, _srcChain(), _dstChain(), _dep(), _dep()), 0, "paused lane is not drift");
  }

  function test_configParity_missingDeploymentRecords() public view {
    Types.Deployment memory empty;
    // dest verifier + dest resolver unrecorded, plus the resolver-address comparison.
    assertEq(script.checkConfigParity(_lane(), _srcChain(), _dstChain(), _dep(), empty), 3, "each gap counted");
  }

  function test_configParity_countsEveryMismatchInOnePass() public view {
    Types.ChainConfig memory dst = _dstChain();
    dst.resolverSalt = bytes32(uint256(999));

    Types.Deployment memory destDeployment = _dep();
    destDeployment.verifiers[0].versionTag = VERSION_TAG_V2; // lane's verifier missing on dest

    Types.LaneConfig memory lane = _lane();
    lane.remote.gasForVerification = 0;

    assertEq(script.checkConfigParity(lane, _srcChain(), dst, _dep(), destDeployment), 3, "no short-circuit");
  }

  // ===========================================================================
  //  TIER 2 — on-chain, source side
  // ===========================================================================

  function test_sourceSide_clean() public view {
    assertEq(script.checkSourceSide(_lane(), _dep()), 0, "source side wired");
  }

  function test_sourceSide_missingOutboundImplementation() public view {
    Types.LaneConfig memory lane = _lane();
    lane.dest.chainSelector = 7777; // never registered
    // Missing outbound impl, plus the unconfigured remote chain config reads back zeroed.
    assertGt(script.checkSourceSide(lane, _dep()), 1, "unregistered dest is multiple mismatches");
  }

  function test_sourceSide_routerMismatch() public view {
    Types.LaneConfig memory lane = _lane();
    lane.remote.router = address(0xBAD);
    assertEq(script.checkSourceSide(lane, _dep()), 1, "router mismatch");
  }

  /// @dev Direction check: the signer set is NOT a source-side concern. Corrupting it
  ///      must not register on this side.
  function test_sourceSide_ignoresSignatureConfig() public view {
    Types.LaneConfig memory lane = _lane();
    lane.signatureConfig.threshold = 99;
    lane.signatureConfig.signers = new address[](0);
    assertEq(script.checkSourceSide(lane, _dep()), 0, "signatures are a dest-side concern");
  }

  // ===========================================================================
  //  TIER 2 — on-chain, dest side
  // ===========================================================================

  function test_destSide_clean() public view {
    assertEq(script.checkDestSide(_lane(), VERSION_TAG, _dep()), 0, "dest side wired");
  }

  /// @dev A verifier recorded on the dest but never registered on its resolver's
  ///      inbound map: one miss for the inbound lookup, one for the unset signer set on
  ///      that verifier. In-flight messages tagged with it would not verify.
  function test_destSide_recordedTagNotRegisteredInbound() public {
    _deploySecondVerifier();
    Types.Deployment memory deployment = _dep();
    deployment.verifiers = new Types.VerifierDeployment[](2);
    deployment.verifiers[0].versionTag = VERSION_TAG;
    deployment.verifiers[0].addr = address(verifier);
    deployment.verifiers[1].versionTag = VERSION_TAG_V2;
    deployment.verifiers[1].addr = address(verifierV2);
    assertEq(script.checkDestSide(_lane(), VERSION_TAG_V2, deployment), 2, "unregistered verifier");
  }

  /// @dev A tag the dest deployment does not record at all cannot be checked on-chain;
  ///      it reverts with the deploy-first message (tier 1 flags it as a mismatch).
  function test_destSide_unrecordedTagReverts() public {
    vm.expectRevert("ConfigLib: no verifier with versionTag 0x00010002 recorded for  - deploy that verifier first");
    // called for its expected revert; the return is irrelevant
    // forge-lint: disable-next-line(unused-return)
    script.checkDestSide(_lane(), VERSION_TAG_V2, _dep());
  }

  function test_destSide_unsetSignatureConfig() public view {
    Types.LaneConfig memory lane = _lane();
    lane.source.chainSelector = 4444; // no signer set for this source
    assertEq(script.checkDestSide(lane, VERSION_TAG, _dep()), 1, "unset signer set is one clear mismatch");
  }

  function test_destSide_thresholdMismatch() public view {
    Types.LaneConfig memory lane = _lane();
    lane.signatureConfig.threshold = THRESHOLD + 1;
    assertEq(script.checkDestSide(lane, VERSION_TAG, _dep()), 1, "threshold mismatch");
  }

  function test_destSide_signerSetMismatch() public view {
    Types.LaneConfig memory lane = _lane();
    lane.signatureConfig.signers[0] = address(0xBAD);
    assertEq(script.checkDestSide(lane, VERSION_TAG, _dep()), 1, "signer set mismatch");
  }

  function test_destSide_signerOrderIsIrrelevant() public view {
    Types.LaneConfig memory lane = _lane();
    address[] memory reversed = new address[](3);
    reversed[0] = signers[2];
    reversed[1] = signers[1];
    reversed[2] = signers[0];
    lane.signatureConfig.signers = reversed;
    assertEq(script.checkDestSide(lane, VERSION_TAG, _dep()), 0, "EnumerableSet order carries no meaning");
  }

  /// @dev Direction check, mirror of the source-side one: the remote chain config is not
  ///      a dest-side concern.
  function test_destSide_ignoresRemoteChainConfig() public view {
    Types.LaneConfig memory lane = _lane();
    lane.remote.router = address(0xBAD);
    lane.remote.gasForVerification = 1;
    assertEq(script.checkDestSide(lane, VERSION_TAG, _dep()), 0, "remote config is a source-side concern");
  }

  // ===========================================================================
  //  reachability is a setup error, never a mismatch
  // ===========================================================================

  function test_sourceSide_unreachableReverts() public {
    Types.Deployment memory deployment = _dep();
    deployment.verifiers[0].addr = address(0xC0DE1E55);
    vm.expectRevert("LaneParityCheck: no code at source verifier (wrong RPC?)");
    // called for its expected revert; the return is irrelevant
    // forge-lint: disable-next-line(unused-return)
    script.checkSourceSide(_lane(), deployment);
  }

  function test_destSide_unreachableReverts() public {
    Types.Deployment memory deployment = _dep();
    deployment.resolver = address(0xC0DE1E55);
    vm.expectRevert("LaneParityCheck: no code at dest resolver (wrong RPC?)");
    // called for its expected revert; the return is irrelevant
    // forge-lint: disable-next-line(unused-return)
    script.checkDestSide(_lane(), VERSION_TAG, deployment);
  }

  // ===========================================================================
  //  fixtures
  // ===========================================================================

  function _lane() internal view returns (Types.LaneConfig memory lane) {
    lane.name = "src_to_dst";
    lane.source = Types.LaneEndpoint({aliasName: SOURCE_ALIAS, chainSelector: SOURCE_SELECTOR});
    lane.dest = Types.LaneEndpoint({aliasName: DEST_ALIAS, chainSelector: DEST_SELECTOR});
    lane.versionTag = VERSION_TAG;
    lane.signatureConfig.threshold = THRESHOLD;
    lane.signatureConfig.signers = signers;
    lane.remote = Types.RemoteChainConfig({
      router: ROUTER,
      feeUSDCents: FEE_USD_CENTS,
      gasForVerification: GAS_FOR_VERIFICATION,
      payloadSizeBytes: PAYLOAD_SIZE_BYTES
    });
  }

  function _srcChain() internal pure returns (Types.ChainConfig memory chainConfig) {
    chainConfig.aliasName = SOURCE_ALIAS;
    chainConfig.chainSelector = SOURCE_SELECTOR;
    chainConfig.resolverSalt = RESOLVER_SALT;
  }

  function _dstChain() internal pure returns (Types.ChainConfig memory chainConfig) {
    chainConfig.aliasName = DEST_ALIAS;
    chainConfig.chainSelector = DEST_SELECTOR;
    chainConfig.resolverSalt = RESOLVER_SALT;
  }

  /// @dev One local deployment stands in for both sides — which is also the correct
  ///      expectation for the resolver-address parity check.
  function _dep() internal view returns (Types.Deployment memory deployment) {
    deployment.factory = address(factory);
    deployment.resolver = address(resolver);
    deployment.verifiers = _verifiersOf(address(verifier));
  }
}
