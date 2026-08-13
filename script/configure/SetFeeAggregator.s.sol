// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";

/// @title SetFeeAggregator
/// @notice Outline step 10 (resolver side). Sets the resolver's fee aggregator.
/// @dev Target call (grounded): VersionedVerifierResolver.setFeeAggregator(address).
///      onlyOwner.
/// @dev This is a SECOND, DISTINCT fee destination from the verifier's
///      DynamicConfig.feeAggregator — set both. A zero fee aggregator is a valid
///      state but intentionally makes fee withdrawals revert.
contract SetFeeAggregator is BaseScript {
  bytes4 internal constant SELECTOR = VersionedVerifierResolver.setFeeAggregator.selector;

  function run(string calldata chainAlias) external {
    _initOutput();

    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);

    console2.log("[SetFeeAggregator] chain:", chainAlias);
    console2.log("  target resolver:", dep.resolver);
    console2.log("  feeAggregator:", roles.resolver.feeAggregator);

    // TODO(step 10): _stage(dep.resolver,
    //   abi.encodeCall(VersionedVerifierResolver.setFeeAggregator, (roles.resolver.feeAggregator)));

    _flush("set-fee-aggregator-resolver");
  }
}
