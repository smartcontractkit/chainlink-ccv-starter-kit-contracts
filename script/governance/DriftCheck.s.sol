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
///        - inbound impl      -> LOCAL resolver,  keyed by each recorded verifier's versionTag
///
/// @dev Verifier-scoped checks run per RECORDED VERIFIER (`deployments/<alias>.json`
///      `verifiers` array), and the resolver maps are compared CLOSED-WORLD: an on-chain
///      inbound registration whose tag is not in the record is drift (a registered
///      inbound verifier is attack surface), as is an outbound entry no lane declares.
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
    // Role holders are per verifier: each recorded verifier is compared against ITS
    // roles entry. A recorded verifier with no entry is drift — the roles file is the
    // machine-checkable intent, and a verifier without intent cannot be checked.
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      string memory prefix = string.concat("verifier ", ConfigLib.tagToString(deployment.verifiers[i].versionTag), " ");
      if (!ConfigLib.hasVerifierRolesTag(roles, deployment.verifiers[i].versionTag)) {
        console2.log(string.concat("DRIFT_DETECTED ", prefix, "has no roles entry in config/roles"));
        ++drift;
        continue;
      }
      Types.VerifierRoles memory expected = ConfigLib.verifierRolesByTag(roles, deployment.verifiers[i].versionTag);

      CommitteeVerifier verifier = CommitteeVerifier(deployment.verifiers[i].addr);
      drift += _diffAddress(string.concat(prefix, "owner"), expected.owner, verifier.owner());
      drift += _diffAddress(
        string.concat(prefix, "storageLocationsAdmin"),
        expected.storageLocationsAdmin,
        verifier.getStorageLocationsAdmin()
      );

      CommitteeVerifier.DynamicConfig memory dynamicConfig = verifier.getDynamicConfig();
      drift += _diffAddress(string.concat(prefix, "feeAggregator"), expected.feeAggregator, dynamicConfig.feeAggregator);
      drift += _diffAddress(
        string.concat(prefix, "allowlistAdmin"), expected.allowlistAdmin, dynamicConfig.allowlistAdmin
      );

      address pendingAdmin = verifier.getPendingStorageLocationsAdmin();
      if (pendingAdmin != address(0)) {
        console2.log(string.concat("  NOTE ", prefix, "has a pending storageLocationsAdmin (not drift):"), pendingAdmin);
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

  /// @notice Chain-scoped verifier state vs the deployment record + `config/chains/<alias>.json`,
  ///         checked per recorded verifier.
  /// @dev `versionTag` is immutable on-chain (`BaseVerifier.i_versionTag`), so a mismatch
  ///      here is unfixable by configuration — it means the recorded address is the wrong
  ///      verifier, or the record was edited after deploy. Flagged loudly for that reason.
  function checkVerifierConfig(
    Types.Deployment memory deployment,
    Types.ChainConfig memory chainConfig
  ) public view returns (uint256 drift) {
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      CommitteeVerifier verifier = CommitteeVerifier(deployment.verifiers[i].addr);
      string memory prefix = string.concat("verifier ", ConfigLib.tagToString(deployment.verifiers[i].versionTag), " ");

      bytes4 onChainTag = verifier.versionTag();
      if (onChainTag != deployment.verifiers[i].versionTag) {
        console2.log(
          string.concat(
            "DRIFT_DETECTED ", prefix, "versionTag (IMMUTABLE - wrong verifier address, or record edited post-deploy)"
          )
        );
        console2.log("  expected:", ConfigLib.tagToString(deployment.verifiers[i].versionTag));
        console2.log("  actual:  ", ConfigLib.tagToString(onChainTag));
        ++drift;
      }

      drift += _diffBytes4(
        string.concat(prefix, "allowedFinalityConfig"), chainConfig.finalityConfig, verifier.getAllowedFinalityConfig()
      );
      drift += _diffStrings(
        string.concat(prefix, "storageLocations"), chainConfig.storageLocations, verifier.getStorageLocations()
      );
    }
  }

  /// @notice Resolver inbound/outbound implementation maps vs deployments + lanes,
  ///         compared CLOSED-WORLD in both directions.
  /// @dev Inbound must equal exactly the recorded verifiers: a recorded tag missing
  ///      on-chain is drift, and an on-chain tag missing from the record is drift too —
  ///      an unknown registered inbound verifier is attack surface, not slack. Outbound
  ///      is derived from lanes (dest selector -> verifier of the lane's versionTag),
  ///      mirroring what `ApplyInbound/OutboundImplementationUpdates` stage; an on-chain
  ///      outbound entry no lane declares is drift for the same reason.
  function checkResolverImplementations(
    Types.Deployment memory deployment,
    Types.ChainConfig memory chainConfig,
    Types.LaneConfig[] memory lanes
  ) public view returns (uint256 drift) {
    if (deployment.resolver == address(0)) return 0;
    VersionedVerifierResolver resolver = VersionedVerifierResolver(deployment.resolver);

    // ---- inbound: recorded entries -> on-chain ----
    VersionedVerifierResolver.InboundImplementationArgs[] memory inbound = resolver.getAllInboundImplementations();
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      address inboundImplementation = address(0);
      for (uint256 j = 0; j < inbound.length; ++j) {
        if (inbound[j].version == deployment.verifiers[i].versionTag) inboundImplementation = inbound[j].verifier;
      }
      drift += _diffAddress(
        string.concat(
          "resolver inbound impl for versionTag ", ConfigLib.tagToString(deployment.verifiers[i].versionTag)
        ),
        deployment.verifiers[i].addr,
        inboundImplementation
      );
    }

    // ---- inbound: on-chain -> recorded entries ----
    for (uint256 i = 0; i < inbound.length; ++i) {
      if (!ConfigLib.hasVerifierTag(deployment, inbound[i].version)) {
        console2.log(
          string.concat(
            "DRIFT_DETECTED resolver inbound impl for UNRECORDED versionTag ",
            ConfigLib.tagToString(inbound[i].version),
            " (unknown registered verifier)"
          )
        );
        console2.log("  actual:", inbound[i].verifier);
        ++drift;
      }
    }

    // ---- outbound: lanes -> on-chain ----
    VersionedVerifierResolver.OutboundImplementationArgs[] memory outbound = resolver.getAllOutboundImplementations();
    for (uint256 i = 0; i < lanes.length; ++i) {
      if (!_stringsEqual(lanes[i].source.aliasName, chainConfig.aliasName)) continue;

      if (!ConfigLib.hasVerifierTag(deployment, lanes[i].versionTag)) {
        console2.log(
          string.concat(
            "DRIFT_DETECTED lane ",
            lanes[i].name,
            " versionTag ",
            ConfigLib.tagToString(lanes[i].versionTag),
            " has no recorded verifier - deploy that verifier first"
          )
        );
        ++drift;
        continue;
      }

      address outboundImplementation = address(0);
      for (uint256 j = 0; j < outbound.length; ++j) {
        if (outbound[j].destChainSelector == lanes[i].dest.chainSelector) {
          outboundImplementation = outbound[j].verifier;
        }
      }
      drift += _diffAddress(
        string.concat("resolver outbound impl for lane ", lanes[i].name),
        ConfigLib.verifierByTag(deployment, lanes[i].versionTag),
        outboundImplementation
      );
    }

    // ---- outbound: on-chain -> lanes ----
    for (uint256 i = 0; i < outbound.length; ++i) {
      bool declared = false;
      for (uint256 j = 0; j < lanes.length; ++j) {
        if (
          _stringsEqual(lanes[j].source.aliasName, chainConfig.aliasName)
            && lanes[j].dest.chainSelector == outbound[i].destChainSelector
        ) declared = true;
      }
      if (!declared) {
        console2.log("DRIFT_DETECTED resolver outbound impl for a dest selector no lane declares");
        console2.log("  dest selector:", outbound[i].destChainSelector);
        console2.log("  actual:", outbound[i].verifier);
        ++drift;
      }
    }
  }

  /// @notice Per-lane verifier state vs `config/lanes/*.json`, direction-aware. Each
  ///         lane is checked on the verifier serving ITS versionTag; a tag with no
  ///         recorded verifier is reported once per leg and the leg skipped.
  function checkLanes(
    Types.Deployment memory deployment,
    Types.ChainConfig memory chainConfig,
    Types.LaneConfig[] memory lanes
  ) public view returns (uint256 drift) {
    for (uint256 i = 0; i < lanes.length; ++i) {
      Types.LaneConfig memory lane = lanes[i];
      string memory lanePrefix = string.concat("lane ", lane.name, " ");

      bool touchesThisChain = _stringsEqual(lane.dest.aliasName, chainConfig.aliasName)
        || _stringsEqual(lane.source.aliasName, chainConfig.aliasName);
      if (!touchesThisChain) continue;

      if (!ConfigLib.hasVerifierTag(deployment, lane.versionTag)) {
        console2.log(
          string.concat(
            "DRIFT_DETECTED ",
            lanePrefix,
            "versionTag ",
            ConfigLib.tagToString(lane.versionTag),
            " has no recorded verifier on this chain"
          )
        );
        ++drift;
        continue;
      }
      CommitteeVerifier verifier = CommitteeVerifier(ConfigLib.verifierByTag(deployment, lane.versionTag));

      // Inbound leg: the signer set that verifies messages ARRIVING from lane.source
      // lives on this chain only when this chain is the destination.
      if (_stringsEqual(lane.dest.aliasName, chainConfig.aliasName)) {
        (address[] memory signers, uint8 threshold) = verifier.getSignatureConfig(lane.source.chainSelector);
        drift += _diffUint(string.concat(lanePrefix, "threshold"), lane.signatureConfig.threshold, threshold);
        drift += _diffSigners(string.concat(lanePrefix, "signers"), lane.signatureConfig.signers, signers);
      }

      // Outbound leg: routing/fee/gas for messages LEAVING to lane.dest lives on this
      // chain only when this chain is the source.
      if (_stringsEqual(lane.source.aliasName, chainConfig.aliasName)) {
        // the other return values are deliberately ignored
        // forge-lint: disable-next-line(unused-return)
        (BaseVerifier.RemoteChainConfigArgs memory remote,) = verifier.getRemoteChainConfig(lane.dest.chainSelector);
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
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      require(
        deployment.verifiers[i].addr.code.length != 0,
        string.concat(
          "DriftCheck: no code at recorded verifier for versionTag ",
          ConfigLib.tagToString(deployment.verifiers[i].versionTag),
          " (wrong --rpc-url?)"
        )
      );
    }
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
    for (uint256 i = 0; i < paths.length; ++i) {
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
    console2.log("  expected:", ConfigLib.tagToString(expected));
    console2.log("  actual:  ", ConfigLib.tagToString(actual));
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
    for (uint256 i = 0; same && i < expected.length; ++i) {
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

  function _stringsEqual(
    string memory left,
    string memory right
  ) private pure returns (bool) {
    return keccak256(bytes(left)) == keccak256(bytes(right));
  }
}
