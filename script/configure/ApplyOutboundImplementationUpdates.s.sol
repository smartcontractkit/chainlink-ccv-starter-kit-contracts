// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {console2} from "forge-std/console2.sol";

/// @title ApplyOutboundImplementationUpdates
/// @notice Points each destination chain
///         selector at the verifier that handles OUTBOUND traffic for it. Batched per
///         chain: ONE call covers every outbound lane originating on this chain, and
///         destinations already matching on-chain are left out of it — so --rpc-url is
///         required in BOTH output modes.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/ApplyOutboundImplementationUpdates.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
///   (EOA path: OUTPUT_MODE=EOA + --broadcast --aws)
contract ApplyOutboundImplementationUpdates is BaseScript {
  /// @notice Single source of truth for the applyOutboundImplementationUpdates calldata.
  function callsFor(
    address resolver,
    VersionedVerifierResolver.OutboundImplementationArgs[] memory args
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({
      to: resolver,
      value: 0,
      data: abi.encodeWithSelector(VersionedVerifierResolver.applyOutboundImplementationUpdates.selector, args)
    });
  }

  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    require(
      deployment.resolver != address(0),
      string.concat("ApplyOutboundImplementationUpdates: resolver not recorded for ", chainAlias)
    );
    require(
      deployment.verifier != address(0),
      string.concat("ApplyOutboundImplementationUpdates: verifier not recorded for ", chainAlias)
    );

    // The diff below reads the resolver, so an unreachable one must fail here with a
    // legible reason rather than as a bare revert inside the first getter call.
    require(
      deployment.resolver.code.length != 0,
      "ApplyOutboundImplementationUpdates: no code at recorded resolver (wrong --rpc-url?)"
    );

    console2.log("[ApplyOutboundImplementationUpdates] chain:", chainAlias);
    console2.log("  target resolver:", deployment.resolver);
    console2.log("  local verifier:", deployment.verifier);

    // Collect every outbound lane whose SOURCE is this chain; map its dest selector to
    // this chain's local verifier. Destinations already mapped to it are left out, so
    // re-running after adding a lane stages only the lane that changed.
    string[] memory lanePaths = ConfigLib.listLanes();
    (VersionedVerifierResolver.OutboundImplementationArgs[] memory args, uint256 matched) =
      _buildOutboundArgs(lanePaths, chainAlias, deployment.resolver, deployment.verifier);
    require(matched > 0, string.concat("ApplyOutboundImplementationUpdates: no outbound lanes for ", chainAlias));

    if (args.length == 0) {
      console2.log("  nothing to do: every outbound destination is already current:", matched);
      return;
    }
    console2.log("  staging destinations:", args.length, "of", matched);

    _stageMany(callsFor(deployment.resolver, args));
    _flush("apply-outbound-implementations");
  }

  /// @notice True when the config already matches on-chain: the resolver routes this
  ///         destination to `verifier`, so staging it again would write the same value.
  function isCurrent(
    address resolver,
    uint64 destChainSelector,
    address verifier
  ) public view returns (bool) {
    // The second parameter is unused extraArgs on the interface.
    return VersionedVerifierResolver(resolver).getOutboundImplementation(destChainSelector, "") == verifier;
  }

  /// @dev Two-pass build (count then fill) since Solidity memory arrays are fixed-size.
  /// @return args One entry per lane that needs writing.
  /// @return matched Lanes with this chain as source, current or not. The two counts
  ///         differ once some are applied, and only `matched == 0` is a config error.
  function _buildOutboundArgs(
    string[] memory lanePaths,
    string memory chainAlias,
    address resolver,
    address verifier
  ) internal view returns (VersionedVerifierResolver.OutboundImplementationArgs[] memory args, uint256 matched) {
    uint256 count = 0;
    for (uint256 i = 0; i < lanePaths.length; ++i) {
      Types.LaneConfig memory lane = ConfigLib.readLaneByPath(lanePaths[i]);
      if (!_stringsEqual(lane.source.aliasName, chainAlias)) continue;
      ++matched;
      if (!isCurrent(resolver, lane.dest.chainSelector, verifier)) count++;
    }

    args = new VersionedVerifierResolver.OutboundImplementationArgs[](count);
    uint256 j = 0;
    for (uint256 i = 0; i < lanePaths.length; ++i) {
      Types.LaneConfig memory lane = ConfigLib.readLaneByPath(lanePaths[i]);
      if (!_stringsEqual(lane.source.aliasName, chainAlias)) continue;
      require(lane.dest.chainSelector != 0, "ApplyOutboundImplementationUpdates: destChainSelector cannot be zero");

      if (isCurrent(resolver, lane.dest.chainSelector, verifier)) {
        console2.log("  lane UNCHANGED:", lane.name);
        continue;
      }
      console2.log("  lane STAGED:", lane.name);
      args[j++] = VersionedVerifierResolver.OutboundImplementationArgs({
        destChainSelector: lane.dest.chainSelector, verifier: verifier
      });
    }
  }
}
