// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {console2} from "forge-std/console2.sol";

/// @title ApplyInboundImplementationUpdates
/// @notice Maps a verifier `versionTag`
///         to the verifier that handles INBOUND traffic for that version. Per chain.
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

  /// @notice Build the single (version -> verifier) mapping for a chain.
  function toInboundArgs(
    bytes4 version,
    address verifier
  ) public pure returns (VersionedVerifierResolver.InboundImplementationArgs[] memory args) {
    args = new VersionedVerifierResolver.InboundImplementationArgs[](1);
    args[0] = VersionedVerifierResolver.InboundImplementationArgs({version: version, verifier: verifier});
  }

  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);

    Types.ChainConfig memory chainConfig = ConfigLib.readChain(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    require(
      deployment.resolver != address(0),
      string.concat("ApplyInboundImplementationUpdates: resolver not recorded for ", chainAlias)
    );
    require(
      deployment.verifier != address(0),
      string.concat("ApplyInboundImplementationUpdates: verifier not recorded for ", chainAlias)
    );
    require(chainConfig.versionTag != bytes4(0), "ApplyInboundImplementationUpdates: versionTag cannot be zero");

    console2.log("[ApplyInboundImplementationUpdates] chain:", chainAlias);
    console2.log("  target resolver:", deployment.resolver);
    console2.log("  version:", vm.toString(chainConfig.versionTag));
    console2.log("  verifier:", deployment.verifier);

    _stageMany(callsFor(deployment.resolver, toInboundArgs(chainConfig.versionTag, deployment.verifier)));
    _flush("apply-inbound-implementations");
  }
}
