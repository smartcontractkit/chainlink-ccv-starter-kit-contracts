// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CREATE2Factory} from "@chainlink/contracts-ccip/contracts/CREATE2Factory.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title DriftCheck
/// @notice READ-ONLY comparison of the FULL declared config
///         (`config/chains`, `config/lanes`, `config/roles`, `config/deployments`)
///         against live on-chain getters. Designed to be CI-schedulable with DISTINCT
///         exit codes for clean / drift / RPC-unavailable — see drift-check.sh,
///         which maps this script's outcome to codes 0 / 1 / 2.
///
/// @dev Convention: on ANY drift, log a line beginning with the marker `DRIFT_DETECTED`
///      and revert. The wrapper greps for that marker to distinguish real drift
///      (exit 1) from an RPC/connection failure (exit 2). A clean run returns
///      normally (exit 0).
///
/// @dev Unreachable contracts are deliberately NOT drift. A recorded address with no
///      code almost always means the wrong `--rpc-url`, not a config mismatch, so it
///      reverts WITHOUT the marker and the wrapper reports exit 2. The code-length
///      guard is load-bearing for a second reason: a staticcall to a codeless address
///      SUCCEEDS with empty returndata, and the ensuing ABI-decode failure is not
///      catchable by try/catch (same trap documented in `BalanceReport`).
///
/// @dev Lane direction follows the same mapping the configure scripts encode, which is
///      dictated by where each value is read on-chain:
///        - signature config  -> DEST verifier,   keyed by SOURCE selector
///          (`getSignatureConfig(sourceChainSelector)`)
///        - remote chain cfg  -> SOURCE verifier, keyed by DEST selector
///          (`getRemoteChainConfig(remoteChainSelector)`)
///        - outbound impl     -> SOURCE resolver, keyed by DEST selector
///        - inbound impl      -> LOCAL resolver,  keyed by this chain's versionTag
///
/// Usage (direct):
///   forge script script/governance/DriftCheck.s.sol --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
/// Usage (CI, with exit-code mapping):
///   script/governance/drift-check.sh sepolia $SEPOLIA_RPC_URL
contract DriftCheck is Script {
  error DriftDetected(uint256 count);

  function run(
    string calldata chainAlias
  ) external view {
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    Types.ChainConfig memory chainConfig = ConfigLib.readChain(chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);
    Types.LaneConfig[] memory lanes = _readLanes();

    console2.log("[DriftCheck] chain:", chainAlias);
    console2.log("  lanes considered:", lanes.length);

    uint256 drift = checkAll(deployment, chainConfig, roles, lanes);

    if (drift > 0) {
      console2.log("DRIFT_DETECTED total mismatches:", drift);
      revert DriftDetected(drift);
    }
    console2.log("[DriftCheck] clean:", chainAlias);
  }

  function checkAll(
    Types.Deployment memory deployment,
    Types.ChainConfig memory chainConfig,
    Types.RolesConfig memory roles,
    Types.LaneConfig[] memory lanes
  ) public view returns (uint256 drift) {
    _assertReachable(deployment);

    drift += checkRoles(deployment, roles);
    drift += checkVerifierConfig(deployment, chainConfig);
    drift += checkResolverImplementations(deployment, chainConfig, lanes);
    drift += checkLanes(deployment, chainConfig, lanes);
  }

  /// @notice Owners and admin/fee roles vs `config/roles/<alias>.json`.
  /// @dev There is no `pendingOwner()` getter on these contracts, so a half-finished
  ///      two-step handover is invisible here; the accept leg must be confirmed by the
  ///      ceremony itself. `getPendingStorageLocationsAdmin()` DOES exist and is
  ///      reported, because a stuck pending admin is a real operational state.
  function checkRoles(
    Types.Deployment memory deployment,
    Types.RolesConfig memory roles
  ) public view returns (uint256 drift) {
    if (deployment.verifier != address(0)) {
      CommitteeVerifier verifier = CommitteeVerifier(deployment.verifier);
      drift += _diffAddress("verifier owner", roles.verifier.owner, verifier.owner());
      drift += _diffAddress(
        "verifier storageLocationsAdmin", roles.verifier.storageLocationsAdmin, verifier.getStorageLocationsAdmin()
      );

      CommitteeVerifier.DynamicConfig memory dynamicConfig = verifier.getDynamicConfig();
      drift += _diffAddress("verifier feeAggregator", roles.verifier.feeAggregator, dynamicConfig.feeAggregator);
      drift += _diffAddress("verifier allowlistAdmin", roles.verifier.allowlistAdmin, dynamicConfig.allowlistAdmin);

      address pendingAdmin = verifier.getPendingStorageLocationsAdmin();
      if (pendingAdmin != address(0)) {
        console2.log("  NOTE verifier has a pending storageLocationsAdmin (not drift):", pendingAdmin);
      }
    }

    if (deployment.resolver != address(0)) {
      VersionedVerifierResolver resolver = VersionedVerifierResolver(deployment.resolver);
      drift += _diffAddress("resolver owner", roles.resolver.owner, resolver.owner());
      drift += _diffAddress("resolver feeAggregator", roles.resolver.feeAggregator, resolver.getFeeAggregator());
    }

    if (deployment.factory != address(0) && roles.factoryOwner != address(0)) {
      drift += _diffAddress("factory owner", roles.factoryOwner, CREATE2Factory(deployment.factory).owner());
    }
  }

  /// @notice Chain-scoped verifier state vs `config/chains/<alias>.json`.
  /// @dev `versionTag` is immutable on-chain (`BaseVerifier.i_versionTag`), so a mismatch
  ///      here is unfixable by configuration — it means the recorded address is the wrong
  ///      verifier, or the config was edited after deploy. Flagged loudly for that reason.
  function checkVerifierConfig(
    Types.Deployment memory deployment,
    Types.ChainConfig memory chainConfig
  ) public view returns (uint256 drift) {
    if (deployment.verifier == address(0)) return 0;
    CommitteeVerifier verifier = CommitteeVerifier(deployment.verifier);

    bytes4 onChainTag = verifier.versionTag();
    if (onChainTag != chainConfig.versionTag) {
      console2.log("DRIFT_DETECTED versionTag (IMMUTABLE - wrong verifier address, or config edited post-deploy)");
      console2.log("  expected:", vm.toString(chainConfig.versionTag));
      console2.log("  actual:  ", vm.toString(onChainTag));
      ++drift;
    }

    drift += _diffBytes4("allowedFinalityConfig", chainConfig.finalityConfig, verifier.getAllowedFinalityConfig());
    drift += _diffStrings("storageLocations", chainConfig.storageLocations, verifier.getStorageLocations());
  }

  /// @notice Resolver inbound/outbound implementation maps vs deployments + lanes.
  /// @dev Inbound is keyed by this chain's versionTag and must point at the LOCAL
  ///      verifier. Outbound is keyed by the dest selector of every lane whose SOURCE
  ///      is this chain, and must also point at the local verifier — mirroring exactly
  ///      what `ApplyInbound/OutboundImplementationUpdates` stage.
  function checkResolverImplementations(
    Types.Deployment memory deployment,
    Types.ChainConfig memory chainConfig,
    Types.LaneConfig[] memory lanes
  ) public view returns (uint256 drift) {
    if (deployment.resolver == address(0) || deployment.verifier == address(0)) return 0;
    VersionedVerifierResolver resolver = VersionedVerifierResolver(deployment.resolver);

    VersionedVerifierResolver.InboundImplementationArgs[] memory inbound = resolver.getAllInboundImplementations();
    address inboundImplementation;
    for (uint256 i; i < inbound.length; ++i) {
      if (inbound[i].version == chainConfig.versionTag) inboundImplementation = inbound[i].verifier;
    }
    drift += _diffAddress(
      "resolver inbound impl for this chain's versionTag", deployment.verifier, inboundImplementation
    );

    VersionedVerifierResolver.OutboundImplementationArgs[] memory outbound = resolver.getAllOutboundImplementations();
    for (uint256 i; i < lanes.length; ++i) {
      if (!_stringsEqual(lanes[i].source.aliasName, chainConfig.aliasName)) continue;

      address outboundImplementation;
      for (uint256 j; j < outbound.length; ++j) {
        if (outbound[j].destChainSelector == lanes[i].dest.chainSelector) {
          outboundImplementation = outbound[j].verifier;
        }
      }
      drift += _diffAddress(
        string.concat("resolver outbound impl for lane ", lanes[i].name), deployment.verifier, outboundImplementation
      );
    }
  }

  /// @notice Per-lane verifier state vs `config/lanes/*.json`, direction-aware.
  function checkLanes(
    Types.Deployment memory deployment,
    Types.ChainConfig memory chainConfig,
    Types.LaneConfig[] memory lanes
  ) public view returns (uint256 drift) {
    if (deployment.verifier == address(0)) return 0;
    CommitteeVerifier verifier = CommitteeVerifier(deployment.verifier);

    for (uint256 i; i < lanes.length; ++i) {
      Types.LaneConfig memory lane = lanes[i];

      // Inbound leg: the signer set that verifies messages ARRIVING from lane.source
      // lives on this chain only when this chain is the destination.
      if (_stringsEqual(lane.dest.aliasName, chainConfig.aliasName)) {
        (address[] memory signers, uint8 threshold) = verifier.getSignatureConfig(lane.source.chainSelector);
        drift += _diffUint(string.concat("lane ", lane.name, " threshold"), lane.signatureConfig.threshold, threshold);
        drift += _diffSigners(string.concat("lane ", lane.name, " signers"), lane.signatureConfig.signers, signers);
      }

      // Outbound leg: routing/fee/gas for messages LEAVING to lane.dest lives on this
      // chain only when this chain is the source.
      if (_stringsEqual(lane.source.aliasName, chainConfig.aliasName)) {
        (BaseVerifier.RemoteChainConfigArgs memory remote,) = verifier.getRemoteChainConfig(lane.dest.chainSelector);
        string memory lanePrefix = string.concat("lane ", lane.name, " ");
        drift += _diffAddress(string.concat(lanePrefix, "router"), lane.remote.router, address(remote.router));
        drift += _diffBool(
          string.concat(lanePrefix, "allowlistEnabled"), lane.allowlist.allowlistEnabled, remote.allowlistEnabled
        );
        drift += _diffUint(string.concat(lanePrefix, "feeUSDCents"), lane.remote.feeUSDCents, remote.feeUSDCents);
        drift += _diffUint(
          string.concat(lanePrefix, "gasForVerification"), lane.remote.gasForVerification, remote.gasForVerification
        );
        drift += _diffUint(
          string.concat(lanePrefix, "payloadSizeBytes"), lane.remote.payloadSizeBytes, remote.payloadSizeBytes
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  //  reachability — an environment problem, never drift
  // ---------------------------------------------------------------------------
  function _assertReachable(
    Types.Deployment memory deployment
  ) private view {
    require(
      deployment.verifier == address(0) || deployment.verifier.code.length != 0,
      "DriftCheck: no code at recorded verifier (wrong --rpc-url?)"
    );
    require(
      deployment.resolver == address(0) || deployment.resolver.code.length != 0,
      "DriftCheck: no code at recorded resolver (wrong --rpc-url?)"
    );
    require(
      deployment.factory == address(0) || deployment.factory.code.length != 0,
      "DriftCheck: no code at recorded factory (wrong --rpc-url?)"
    );
  }

  function _readLanes() private view returns (Types.LaneConfig[] memory lanes) {
    string[] memory paths = ConfigLib.listLanes();
    lanes = new Types.LaneConfig[](paths.length);
    for (uint256 i; i < paths.length; ++i) {
      lanes[i] = ConfigLib.readLaneByPath(paths[i]);
    }
  }

  // ---------------------------------------------------------------------------
  //  comparators — each logs the marker and returns 1 on mismatch, else 0
  // ---------------------------------------------------------------------------
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

  function _diffBool(
    string memory label,
    bool expected,
    bool actual
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

  /// @dev Storage locations are a plain `string[]` on-chain (`BaseVerifier.s_storageLocations`,
  ///      cleared and re-pushed on every update), so ORDER is meaningful and compared.
  function _diffStrings(
    string memory label,
    string[] memory expected,
    string[] memory actual
  ) private pure returns (uint256) {
    bool same = expected.length == actual.length;
    for (uint256 i; same && i < expected.length; ++i) {
      if (!_stringsEqual(expected[i], actual[i])) same = false;
    }
    if (same) return 0;
    console2.log(string.concat("DRIFT_DETECTED ", label));
    console2.log("  expected count:", expected.length);
    console2.log("  actual count:  ", actual.length);
    return 1;
  }

  /// @dev The on-chain signer set is an EnumerableSet, so its iteration order is
  ///      insertion order and carries no meaning — compared as a SET, not a list.
  ///      (Ordering only matters for the signatures supplied at verification time.)
  function _diffSigners(
    string memory label,
    address[] memory expected,
    address[] memory actual
  ) private pure returns (uint256) {
    bool same = expected.length == actual.length;
    for (uint256 i; same && i < expected.length; ++i) {
      bool found;
      for (uint256 j; j < actual.length; ++j) {
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

  function _stringsEqual(
    string memory left,
    string memory right
  ) private pure returns (bool) {
    return keccak256(bytes(left)) == keccak256(bytes(right));
  }
}
