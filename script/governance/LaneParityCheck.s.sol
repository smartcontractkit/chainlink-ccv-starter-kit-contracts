// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title LaneParityCheck
/// @notice READ-ONLY check of the invariants a lane must satisfy ACROSS its two chains.
///         `DriftCheck` asks "does chain X match X's config?" — one alias, one RPC. It
///         cannot ask "are A's half and B's half mutually consistent?", and a lane whose
///         halves disagree passes drift on both sides while every message fails on first
///         use.
///
/// @dev `remoteChainConfig` is keyed by DEST selector and lives on the SOURCE chain;
///      `signatureConfig` is keyed by SOURCE selector and lives on the DEST chain.
/// @dev Emits the same `DRIFT_DETECTED` marker as `DriftCheck`, so one wrapper shape
///      covers both. Unreachable contracts revert without the marker (exit 2, not 1).
///
/// Usage:
///   forge script script/governance/LaneParityCheck.s.sol --sig "runConfig(string)" <lane>
///   forge script script/governance/LaneParityCheck.s.sol --sig "runSource(string)" <lane> --rpc-url $SOURCE_RPC
///   forge script script/governance/LaneParityCheck.s.sol --sig "runDest(string)"   <lane> --rpc-url $DEST_RPC
///   script/governance/lane-parity-check.sh <lane> $SOURCE_RPC $DEST_RPC
contract LaneParityCheck is Script {
  error ParityMismatch(uint256 count);

  /// @notice Config-vs-config invariants. Needs no chain.
  function runConfig(
    string calldata laneName
  ) external view {
    Types.LaneConfig memory lane = ConfigLib.readLane(laneName);
    _header(lane);
    _finish(
      lane,
      checkConfigParity(
        lane,
        ConfigLib.readChain(lane.source.aliasName),
        ConfigLib.readChain(lane.dest.aliasName),
        ConfigLib.readDeployment(lane.source.aliasName),
        ConfigLib.readDeployment(lane.dest.aliasName)
      )
    );
  }

  /// @notice Run with `--rpc-url` pointing at the lane's SOURCE chain.
  function runSource(
    string calldata laneName
  ) external view {
    Types.LaneConfig memory lane = ConfigLib.readLane(laneName);
    _header(lane);
    _finish(lane, checkSourceSide(lane, ConfigLib.readDeployment(lane.source.aliasName)));
  }

  /// @notice Run with `--rpc-url` pointing at the lane's DEST chain.
  /// @dev The expected tag comes from the SOURCE chain config: the inbound map is keyed
  ///      by the source generation's tag, not by whatever the dest declares.
  function runDest(
    string calldata laneName
  ) external view {
    Types.LaneConfig memory lane = ConfigLib.readLane(laneName);
    _header(lane);
    _finish(
      lane,
      checkDestSide(
        lane, ConfigLib.readChain(lane.source.aliasName).versionTag, ConfigLib.readDeployment(lane.dest.aliasName)
      )
    );
  }

  function _header(
    Types.LaneConfig memory lane
  ) private pure {
    console2.log("[LaneParityCheck] lane:", lane.name);
    console2.log("  source:", lane.source.aliasName);
    console2.log("  dest:  ", lane.dest.aliasName);
  }

  function _finish(
    Types.LaneConfig memory lane,
    uint256 mismatches
  ) private pure {
    if (mismatches > 0) {
      console2.log("DRIFT_DETECTED total lane parity mismatches:", mismatches);
      revert ParityMismatch(mismatches);
    }
    console2.log("[LaneParityCheck] parity OK:", lane.name);
  }

  // ===========================================================================
  //  TIER 1 — config vs config. No RPC. Runs anywhere.
  // ===========================================================================

  /// @notice Invariants derivable from committed files alone. Takes structs so CI and
  ///         tests can call it without file fixtures.
  function checkConfigParity(
    Types.LaneConfig memory lane,
    Types.ChainConfig memory sourceChain,
    Types.ChainConfig memory destChain,
    Types.Deployment memory sourceDeployment,
    Types.Deployment memory destDeployment
  ) public pure returns (uint256 mismatches) {
    // A stale selector registers the outbound implementation under a key no message arrives with.
    mismatches += _diffUint(
      "source selector: lane vs chain config", sourceChain.chainSelector, lane.source.chainSelector
    );
    mismatches += _diffUint("dest selector: lane vs chain config", destChain.chainSelector, lane.dest.chainSelector);

    // The tag in `verifierResults` originates on the source, and the dest verifier
    // rejects any tag != its own immutable tag.
    mismatches += _diffBytes4(
      "versionTag must be identical on both chains", sourceChain.versionTag, destChain.versionTag
    );

    // Identical salt is necessary but not sufficient (factory address and initcode must
    // match too), so the recorded addresses are compared as well.
    mismatches += _diffBytes32(
      "resolverSalt must be identical on both chains", sourceChain.resolverSalt, destChain.resolverSalt
    );
    mismatches += _diffAddress(
      "recorded resolver address must be identical", sourceDeployment.resolver, destDeployment.resolver
    );

    if (sourceDeployment.verifier == address(0)) mismatches += _report("source verifier not recorded");
    if (destDeployment.verifier == address(0)) mismatches += _report("dest verifier not recorded");
    if (sourceDeployment.resolver == address(0)) mismatches += _report("source resolver not recorded");
    if (destDeployment.resolver == address(0)) mismatches += _report("dest resolver not recorded");

    // BaseVerifier reverts DestGasCannotBeZero regardless of the router value.
    if (lane.remote.gasForVerification == 0) mismatches += _report("lane gasForVerification is zero");

    // router == 0 is the outbound kill switch: a valid state, so NOTE not mismatch.
    if (lane.remote.router == address(0)) {
      console2.log("  NOTE lane router is zero: outbound is PAUSED for this lane (not a mismatch)");
    }
  }

  // ===========================================================================
  //  TIER 2 — on-chain, one chain per leg
  // ===========================================================================

  /// @notice Source-side invariants, keyed by DEST selector.
  function checkSourceSide(
    Types.LaneConfig memory lane,
    Types.Deployment memory sourceDeployment
  ) public view returns (uint256 mismatches) {
    _assertReachable(sourceDeployment, "source");

    address outbound = _outboundImplementation(sourceDeployment.resolver, lane.dest.chainSelector);
    mismatches += _diffAddress("source outbound implementation for dest selector", sourceDeployment.verifier, outbound);

    (
      BaseVerifier.RemoteChainConfigArgs memory remote,
      // the other return values are deliberately ignored
      // forge-lint: disable-next-line(unused-return)
    ) = CommitteeVerifier(sourceDeployment.verifier).getRemoteChainConfig(lane.dest.chainSelector);
    mismatches += _diffAddress("source remoteChainConfig.router", lane.remote.router, address(remote.router));
    mismatches += _diffUint(
      "source remoteChainConfig.gasForVerification", lane.remote.gasForVerification, remote.gasForVerification
    );
    mismatches += _diffUint("source remoteChainConfig.feeUSDCents", lane.remote.feeUSDCents, remote.feeUSDCents);
    mismatches += _diffUint(
      "source remoteChainConfig.payloadSizeBytes", lane.remote.payloadSizeBytes, remote.payloadSizeBytes
    );
  }

  /// @notice Destination-side invariants. The signer set is keyed by source selector and
  ///         the inbound implementation by the source generation's `versionTag`.
  function checkDestSide(
    Types.LaneConfig memory lane,
    bytes4 sourceVersionTag,
    Types.Deployment memory destDeployment
  ) public view returns (uint256 mismatches) {
    _assertReachable(destDeployment, "dest");

    address inbound = _inboundImplementation(destDeployment.resolver, sourceVersionTag);
    mismatches += _diffAddress("dest inbound implementation for SOURCE versionTag", destDeployment.verifier, inbound);

    bytes4 destTag = CommitteeVerifier(destDeployment.verifier).versionTag();
    if (destTag != sourceVersionTag) {
      console2.log("DRIFT_DETECTED dest verifier tag != source tag (IMMUTABLE - every message would fail)");
      console2.log("  source:", vm.toString(sourceVersionTag));
      console2.log("  dest:  ", vm.toString(destTag));
      ++mismatches;
    }

    (address[] memory signers, uint8 threshold) =
      CommitteeVerifier(destDeployment.verifier).getSignatureConfig(lane.source.chainSelector);
    if (threshold == 0) {
      mismatches += _report("dest signatureConfig for source selector is UNSET (threshold 0)");
    } else {
      mismatches += _diffUint("dest signatureConfig threshold", lane.signatureConfig.threshold, threshold);
      mismatches += _diffSigners("dest signatureConfig signers", lane.signatureConfig.signers, signers);
    }
  }

  // ===========================================================================
  //  helpers
  // ===========================================================================

  function _assertReachable(
    Types.Deployment memory deployment,
    string memory side
  ) private view {
    require(
      deployment.verifier.code.length != 0,
      string.concat("LaneParityCheck: no code at ", side, " verifier (wrong RPC?)")
    );
    require(
      deployment.resolver.code.length != 0,
      string.concat("LaneParityCheck: no code at ", side, " resolver (wrong RPC?)")
    );
  }

  function _outboundImplementation(
    address resolver,
    uint64 destSelector
  ) private view returns (address implementation) {
    VersionedVerifierResolver.OutboundImplementationArgs[] memory all =
      VersionedVerifierResolver(resolver).getAllOutboundImplementations();
    for (uint256 i = 0; i < all.length; ++i) {
      if (all[i].destChainSelector == destSelector) return all[i].verifier;
    }
  }

  function _inboundImplementation(
    address resolver,
    bytes4 version
  ) private view returns (address implementation) {
    VersionedVerifierResolver.InboundImplementationArgs[] memory all =
      VersionedVerifierResolver(resolver).getAllInboundImplementations();
    for (uint256 i = 0; i < all.length; ++i) {
      if (all[i].version == version) return all[i].verifier;
    }
  }

  // ---- comparators: log the marker, return 1 on mismatch ----

  function _report(
    string memory label
  ) private pure returns (uint256) {
    console2.log(string.concat("DRIFT_DETECTED ", label));
    return 1;
  }

  function _diffAddress(
    string memory label,
    address expected,
    address actual
  ) private pure returns (uint256) {
    if (expected == actual) return 0;
    console2.log(string.concat("DRIFT_DETECTED ", label));
    console2.log("  expected:", expected);
    console2.log("  actual:  ", actual);
    return 1;
  }

  function _diffUint(
    string memory label,
    uint256 expected,
    uint256 actual
  ) private pure returns (uint256) {
    if (expected == actual) return 0;
    console2.log(string.concat("DRIFT_DETECTED ", label));
    console2.log("  expected:", expected);
    console2.log("  actual:  ", actual);
    return 1;
  }

  function _diffBytes4(
    string memory label,
    bytes4 expected,
    bytes4 actual
  ) private pure returns (uint256) {
    if (expected == actual) return 0;
    console2.log(string.concat("DRIFT_DETECTED ", label));
    console2.log("  expected:", vm.toString(expected));
    console2.log("  actual:  ", vm.toString(actual));
    return 1;
  }

  function _diffBytes32(
    string memory label,
    bytes32 expected,
    bytes32 actual
  ) private pure returns (uint256) {
    if (expected == actual) return 0;
    console2.log(string.concat("DRIFT_DETECTED ", label));
    console2.log("  expected:", vm.toString(expected));
    console2.log("  actual:  ", vm.toString(actual));
    return 1;
  }

  /// @dev Set comparison: the on-chain signer set is an EnumerableSet, so order carries
  ///      no meaning (same rule as `DriftCheck`).
  function _diffSigners(
    string memory label,
    address[] memory expected,
    address[] memory actual
  ) private pure returns (uint256) {
    bool same = expected.length == actual.length;
    for (uint256 i = 0; same && i < expected.length; ++i) {
      bool found = false;
      for (uint256 j = 0; j < actual.length; ++j) {
        if (expected[i] == actual[j]) {
          found = true;
          break;
        }
      }
      if (!found) same = false;
    }
    if (same) return 0;
    console2.log(string.concat("DRIFT_DETECTED ", label));
    console2.log("  expected count:", expected.length);
    console2.log("  actual count:  ", actual.length);
    return 1;
  }
}
