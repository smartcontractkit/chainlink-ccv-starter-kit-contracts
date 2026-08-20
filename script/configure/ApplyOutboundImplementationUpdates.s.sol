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
///         chain: one call covers every outbound lane originating on this chain.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/ApplyOutboundImplementationUpdates.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
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
    _initOutput();

    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    require(
      dep.resolver != address(0),
      string.concat("ApplyOutboundImplementationUpdates: resolver not recorded for ", chainAlias)
    );
    require(
      dep.verifier != address(0),
      string.concat("ApplyOutboundImplementationUpdates: verifier not recorded for ", chainAlias)
    );

    // Collect every outbound lane whose SOURCE is this chain; map its dest selector
    // to this chain's local verifier.
    string[] memory lanePaths = ConfigLib.listLanes();
    VersionedVerifierResolver.OutboundImplementationArgs[] memory args =
      _buildOutboundArgs(lanePaths, chainAlias, dep.verifier);
    require(args.length > 0, string.concat("ApplyOutboundImplementationUpdates: no outbound lanes for ", chainAlias));

    console2.log("[ApplyOutboundImplementationUpdates] chain:", chainAlias);
    console2.log("  target resolver:", dep.resolver);
    console2.log("  local verifier:", dep.verifier);
    console2.log("  outbound destinations:", args.length);

    _stageMany(callsFor(dep.resolver, args));
    _flush("apply-outbound-implementations");
  }

  /// @dev Two-pass build (count then fill) since Solidity memory arrays are fixed-size.
  function _buildOutboundArgs(
    string[] memory lanePaths,
    string memory chainAlias,
    address verifier
  ) internal view returns (VersionedVerifierResolver.OutboundImplementationArgs[] memory args) {
    uint256 count;
    for (uint256 i; i < lanePaths.length; ++i) {
      Types.LaneConfig memory lane = ConfigLib.readLaneByPath(lanePaths[i]);
      if (_eq(lane.source.aliasName, chainAlias)) count++;
    }

    args = new VersionedVerifierResolver.OutboundImplementationArgs[](count);
    uint256 j;
    for (uint256 i; i < lanePaths.length; ++i) {
      Types.LaneConfig memory lane = ConfigLib.readLaneByPath(lanePaths[i]);
      if (!_eq(lane.source.aliasName, chainAlias)) continue;
      require(lane.dest.chainSelector != 0, "ApplyOutboundImplementationUpdates: destChainSelector cannot be zero");
      args[j++] = VersionedVerifierResolver.OutboundImplementationArgs({
        destChainSelector: lane.dest.chainSelector, verifier: verifier
      });
    }
  }
}
