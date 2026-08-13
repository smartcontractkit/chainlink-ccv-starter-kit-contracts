// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";

/// @title SetDynamicConfig
/// @notice Outline step 10 (verifier side). Sets the CommitteeVerifier DynamicConfig
///         { feeAggregator, allowlistAdmin }.
/// @dev Target call (grounded):
///        CommitteeVerifier.setDynamicConfig(DynamicConfig{address feeAggregator, address allowlistAdmin})
///      onlyOwner.
/// @dev IMPORTANT: the verifier's DynamicConfig.feeAggregator and the RESOLVER's
///      setFeeAggregator are TWO DISTINCT fee destinations. Set BOTH (see
///      SetFeeAggregator.s.sol for the resolver side).
contract SetDynamicConfig is BaseScript {
  bytes4 internal constant SELECTOR = CommitteeVerifier.setDynamicConfig.selector;

  function run(string calldata chainAlias) external {
    _initOutput();

    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);

    console2.log("[SetDynamicConfig] chain:", chainAlias);
    console2.log("  target verifier:", dep.verifier);
    console2.log("  feeAggregator:", roles.verifier.feeAggregator);
    console2.log("  allowlistAdmin:", roles.verifier.allowlistAdmin);

    // TODO(step 10): build CommitteeVerifier.DynamicConfig from roles.verifier and:
    //   _stage(dep.verifier, abi.encodeCall(CommitteeVerifier.setDynamicConfig, (dyn)));

    _flush("set-dynamic-config");
  }
}
