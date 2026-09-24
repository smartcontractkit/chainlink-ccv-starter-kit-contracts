// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {console2} from "forge-std/console2.sol";

/// @title SetDynamicConfig
/// @notice Sets the CommitteeVerifier DynamicConfig
///         { feeAggregator, allowlistAdmin }. Per verifier: the versionTag
///         argument selects which recorded verifier (and which roles entry).
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/SetDynamicConfig.s.sol \
///     --sig "run(string,bytes4)" sepolia 0x00010001 --rpc-url $SEPOLIA_RPC_URL
contract SetDynamicConfig is BaseScript {
  /// @notice Single source of truth for the setDynamicConfig calldata.
  function callFor(
    address verifier,
    CommitteeVerifier.DynamicConfig memory dynamicConfig
  ) public pure returns (Call memory call) {
    call = Call({to: verifier, value: 0, data: abi.encodeCall(CommitteeVerifier.setDynamicConfig, (dynamicConfig))});
  }

  /// @notice Translate one verifier's roles-as-data into the verifier DynamicConfig struct.
  function toDynamicConfig(
    Types.VerifierRoles memory verifierRoles
  ) public pure returns (CommitteeVerifier.DynamicConfig memory) {
    return CommitteeVerifier.DynamicConfig({
      feeAggregator: verifierRoles.feeAggregator, allowlistAdmin: verifierRoles.allowlistAdmin
    });
  }

  function run(
    string calldata chainAlias,
    bytes4 versionTag
  ) external {
    _initOutput(chainAlias);

    // Both lookups revert with a legible reason when the tag is unknown: the
    // record defines which tags exist, the operator file carries that verifier's intent.
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    address verifier = ConfigLib.verifierByTag(deployment, versionTag);
    _assertReachable(verifier, "verifier");
    Types.VerifierRoles memory verifierRoles =
    ConfigLib.verifierConfigByTag(ConfigLib.readOperator(chainAlias), versionTag).roles;

    console2.log("[SetDynamicConfig] chain:", chainAlias);
    console2.log("  versionTag:", ConfigLib.tagToString(versionTag));
    console2.log("  target verifier:", verifier);
    console2.log("  feeAggregator:", verifierRoles.feeAggregator);
    console2.log("  allowlistAdmin:", verifierRoles.allowlistAdmin);

    if (verifierRoles.feeAggregator == address(0)) {
      console2.log("  WARN verifier feeAggregator is zero: fee withdrawals will revert until set");
    }

    _stage(callFor(verifier, toDynamicConfig(verifierRoles)));
    _flush(string.concat("set-dynamic-config-", ConfigLib.tagToString(versionTag)));
  }
}
