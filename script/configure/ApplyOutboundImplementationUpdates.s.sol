// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {console2} from "forge-std/console2.sol";

/// @title ApplyOutboundImplementationUpdates
/// @notice Points each destination chain
///         selector at the verifier serving that lane's `versionTag` — the outbound map
///         is COMPILED FROM LANES, so a lane's tag is its outbound entry. Batched per
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
  function callFor(
    address resolver,
    VersionedVerifierResolver.OutboundImplementationArgs[] memory args
  ) public pure returns (Call memory call) {
    call = Call({
      to: resolver, value: 0, data: abi.encodeCall(VersionedVerifierResolver.applyOutboundImplementationUpdates, (args))
    });
  }

  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    // The diff below reads the resolver, so an unreachable one must fail here with a
    // legible reason rather than as a bare revert inside the first getter call.
    _assertReachable(deployment.resolver, "resolver");

    console2.log("[ApplyOutboundImplementationUpdates] chain:", chainAlias);
    console2.log("  target resolver:", deployment.resolver);

    // Collect every outbound lane whose SOURCE is this chain; map its dest selector to
    // the local verifier serving the lane's versionTag. Destinations already mapped to
    // it are left out, so re-running after adding a lane stages only the lane that changed.
    (VersionedVerifierResolver.OutboundImplementationArgs[] memory args, uint256 matched) =
      argsFor(ConfigLib.readLanes(), chainAlias, deployment);
    require(matched > 0, string.concat("ApplyOutboundImplementationUpdates: no outbound lanes for ", chainAlias));

    if (args.length == 0) {
      console2.log("  nothing to do: every outbound destination is already current:", matched);
      return;
    }
    console2.log("  staging destinations:", args.length, "of", matched);

    _stage(callFor(deployment.resolver, args));
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

  /// @notice The args a run would stage: one entry per lane whose SOURCE is `chainAlias`,
  ///         minus the destinations the resolver already routes to that lane's verifier.
  /// @dev No versionTag filter, unlike the verifier-scoped scripts: the resolver maps a
  ///      destination to whichever verifier serves that lane's tag, so one call spans tags.
  /// @return args The entries to send, in lane order. Its length IS the staged count.
  /// @return matched Lanes with this chain as source, current or not. The two counts
  ///         differ once some are applied, and only `matched == 0` is a config error.
  function argsFor(
    Types.LaneConfig[] memory lanes,
    string memory chainAlias,
    Types.Deployment memory deployment
  ) public view returns (VersionedVerifierResolver.OutboundImplementationArgs[] memory args, uint256 matched) {
    // Sized to the upper bound, trimmed to the staged count below.
    args = new VersionedVerifierResolver.OutboundImplementationArgs[](lanes.length);
    uint256 staged = 0;

    for (uint256 i = 0; i < lanes.length; ++i) {
      Types.LaneConfig memory lane = lanes[i];
      if (!_stringsEqual(lane.source.aliasName, chainAlias)) continue;
      ++matched;
      require(lane.dest.chainSelector != 0, "ApplyOutboundImplementationUpdates: destChainSelector cannot be zero");

      address verifier = ConfigLib.verifierByTag(deployment, lane.versionTag);
      if (isCurrent(deployment.resolver, lane.dest.chainSelector, verifier)) {
        console2.log("  lane UNCHANGED:", lane.name);
        continue;
      }

      console2.log("  lane STAGED:", lane.name);
      console2.log("    versionTag / verifier:", ConfigLib.tagToString(lane.versionTag), verifier);
      args[staged++] = VersionedVerifierResolver.OutboundImplementationArgs({
        destChainSelector: lane.dest.chainSelector, verifier: verifier
      });
    }

    // Drop the unused tail: a memory array's first word is its length, and `staged` only
    // ever shrinks it. The zero-filled tail would map destination selector 0.
    // solhint-disable-next-line no-inline-assembly
    assembly {
      mstore(args, staged)
    }
  }
}
