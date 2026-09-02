// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {console2} from "forge-std/console2.sol";

/// @title ApplyInboundImplementationUpdates
/// @notice Maps each verifier `versionTag` to the LOCAL verifier deployed for it, on the
///         resolver's inbound map. The tag set is derived from lanes: every lane whose
///         DEST is this chain names the versionTag its messages arrive tagged with.
///         Batched per chain, and tags already matching on-chain are left out — so
///         --rpc-url is required in BOTH output modes.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/ApplyInboundImplementationUpdates.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
contract ApplyInboundImplementationUpdates is BaseScript {
  /// @notice Single source of truth for the applyInboundImplementationUpdates calldata.
  function callsFor(
    address resolver,
    VersionedVerifierResolver.InboundImplementationArgs[] memory args
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({
      to: resolver, value: 0, data: abi.encodeCall(VersionedVerifierResolver.applyInboundImplementationUpdates, (args))
    });
  }

  /// @notice Build a single (version -> verifier) mapping entry.
  function toInboundArgs(
    bytes4 version,
    address verifier
  ) public pure returns (VersionedVerifierResolver.InboundImplementationArgs[] memory args) {
    args = new VersionedVerifierResolver.InboundImplementationArgs[](1);
    args[0] = VersionedVerifierResolver.InboundImplementationArgs({version: version, verifier: verifier});
  }

  /// @notice True when the resolver already routes this version to `verifier`.
  function isCurrent(
    address resolver,
    bytes4 version,
    address verifier
  ) public view returns (bool) {
    return VersionedVerifierResolver(resolver).getInboundImplementation(abi.encodePacked(version)) == verifier;
  }

  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    // The diff below reads the resolver, so an unreachable one must fail here with a
    // legible reason rather than as a bare revert inside the first getter call.
    _assertReachable(deployment.resolver, "resolver");

    console2.log("[ApplyInboundImplementationUpdates] chain:", chainAlias);
    console2.log("  target resolver:", deployment.resolver);

    bytes4[] memory tags = _inboundTags(ConfigLib.listLanes(), chainAlias);
    if (tags.length == 0) {
      console2.log("  nothing to do: no lane has this chain as destination");
      return;
    }

    (VersionedVerifierResolver.InboundImplementationArgs[] memory args, uint256 staged) =
      _buildInboundArgs(deployment, tags);
    if (staged == 0) {
      console2.log("  nothing to do: every inbound version is already current:", tags.length);
      return;
    }
    console2.log("  staging versions:", staged, "of", tags.length);

    _stageMany(callsFor(deployment.resolver, args));
    _flush("apply-inbound-implementations");
  }

  /// @dev The unique `versionTag` set over every lane whose DEST is this chain.
  function _inboundTags(
    string[] memory lanePaths,
    string memory chainAlias
  ) internal view returns (bytes4[] memory tags) {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](lanePaths.length);
    for (uint256 i = 0; i < lanePaths.length; ++i) {
      lanes[i] = ConfigLib.readLaneByPath(lanePaths[i]);
    }
    return _dedupedDestTags(lanes, chainAlias);
  }

  /// @dev Selection half of _inboundTags, kept pure so it is testable with
  ///      in-memory lanes (readLaneByPath validates tags against the repo catalog).
  function _dedupedDestTags(
    Types.LaneConfig[] memory lanes,
    string memory chainAlias
  ) internal pure returns (bytes4[] memory tags) {
    bytes4[] memory buf = new bytes4[](lanes.length);
    uint256 n = 0;
    for (uint256 i = 0; i < lanes.length; ++i) {
      if (!_stringsEqual(lanes[i].dest.aliasName, chainAlias)) continue;
      bool seen = false;
      for (uint256 j = 0; j < n; ++j) {
        if (buf[j] == lanes[i].versionTag) seen = true;
      }
      if (!seen) buf[n++] = lanes[i].versionTag;
    }

    tags = new bytes4[](n);
    for (uint256 i = 0; i < n; ++i) {
      tags[i] = buf[i];
    }
  }

  /// @dev Resolves each tag against the deployment record (reverting if that tag
  ///      was never deployed here) and drops the tags already current on-chain.
  function _buildInboundArgs(
    Types.Deployment memory deployment,
    bytes4[] memory tags
  ) private view returns (VersionedVerifierResolver.InboundImplementationArgs[] memory args, uint256 staged) {
    uint256 count = 0;
    for (uint256 i = 0; i < tags.length; ++i) {
      if (!isCurrent(deployment.resolver, tags[i], ConfigLib.verifierByTag(deployment, tags[i]))) count++;
    }

    args = new VersionedVerifierResolver.InboundImplementationArgs[](count);
    for (uint256 i = 0; i < tags.length; ++i) {
      address verifier = ConfigLib.verifierByTag(deployment, tags[i]);
      if (isCurrent(deployment.resolver, tags[i], verifier)) {
        console2.log("  version UNCHANGED:", ConfigLib.tagToString(tags[i]));
        continue;
      }
      console2.log("  version STAGED:", ConfigLib.tagToString(tags[i]));
      console2.log("    verifier:", verifier);
      args[staged++] = VersionedVerifierResolver.InboundImplementationArgs({version: tags[i], verifier: verifier});
    }
  }
}
