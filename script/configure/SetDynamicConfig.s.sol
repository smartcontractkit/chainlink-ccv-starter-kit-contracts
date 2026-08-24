// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {console2} from "forge-std/console2.sol";

/// @title SetDynamicConfig
/// @notice Sets the CommitteeVerifier DynamicConfig
///         { feeAggregator, allowlistAdmin }. Per chain / per verifier.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/SetDynamicConfig.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
contract SetDynamicConfig is BaseScript {
  /// @notice Single source of truth for the setDynamicConfig calldata.
  function callsFor(
    address verifier,
    CommitteeVerifier.DynamicConfig memory dynamicConfig
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({
      to: verifier, value: 0, data: abi.encodeWithSelector(CommitteeVerifier.setDynamicConfig.selector, dynamicConfig)
    });
  }

  /// @notice Translate roles-as-data into the verifier DynamicConfig struct.
  function toDynamicConfig(
    Types.RolesConfig memory roles
  ) public pure returns (CommitteeVerifier.DynamicConfig memory) {
    return CommitteeVerifier.DynamicConfig({
      feeAggregator: roles.verifier.feeAggregator, allowlistAdmin: roles.verifier.allowlistAdmin
    });
  }

  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);

    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    require(
      deployment.verifier != address(0), string.concat("SetDynamicConfig: verifier not recorded for ", chainAlias)
    );

    console2.log("[SetDynamicConfig] chain:", chainAlias);
    console2.log("  target verifier:", deployment.verifier);
    console2.log("  feeAggregator:", roles.verifier.feeAggregator);
    console2.log("  allowlistAdmin:", roles.verifier.allowlistAdmin);

    if (roles.verifier.feeAggregator == address(0)) {
      console2.log("  WARN verifier feeAggregator is zero: fee withdrawals will revert until set");
    }

    _stageMany(callsFor(deployment.verifier, toDynamicConfig(roles)));
    _flush("set-dynamic-config");
  }
}
