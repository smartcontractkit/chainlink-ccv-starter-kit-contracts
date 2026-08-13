// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";

/// @title ApplyInboundImplementationUpdates
/// @notice Outline step 11 (resolver, per version tag). Maps each verifier version
///         to the verifier that handles its INBOUND traffic.
/// @dev Target call (grounded):
///        VersionedVerifierResolver.applyInboundImplementationUpdates(InboundImplementationArgs[])
///        InboundImplementationArgs = { bytes4 version; address verifier }
///      This is the mapping keyed by `versionTag`. Rotating a verifier => add the
///      new (version, verifier) mapping here, then re-point outbound.
///      A zero verifier clears the mapping for that version.
contract ApplyInboundImplementationUpdates is BaseScript {
  bytes4 internal constant SELECTOR = VersionedVerifierResolver.applyInboundImplementationUpdates.selector;

  function run(string calldata chainAlias) external {
    _initOutput();

    Types.ChainConfig memory cc = ConfigLib.readChain(chainAlias);
    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);

    console2.log("[ApplyInboundImplementationUpdates] chain:", chainAlias);
    console2.log("  target resolver:", dep.resolver);
    console2.log("  version tag:", vm.toString(cc.versionTag));
    console2.log("  verifier:", dep.verifier);

    // TODO(step 11): build InboundImplementationArgs{version: cc.versionTag, verifier: dep.verifier} and:
    //   _stage(dep.resolver, abi.encodeCall(
    //     VersionedVerifierResolver.applyInboundImplementationUpdates, (args)));

    _flush("apply-inbound-implementations");
  }
}
