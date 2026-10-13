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
/// @dev A zero feeAggregator is fatal unless ALLOW_ZERO_FEE_AGGREGATOR=true: the verifier
///      keeps accruing fees while every withdrawal reverts, so they are stranded until an
///      owner-gated fix lands (the invariant DeployVerifier enforces at deploy). A zero
///      allowlistAdmin is allowed ("no admin"), but the script warns when it would clear
///      a non-zero on-chain admin. A config that already matches the chain stages nothing.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/SetDynamicConfig.s.sol \
///     --sig "run(string,bytes4)" sepolia 0x00010001 --rpc-url $SEPOLIA_RPC_URL
contract SetDynamicConfig is BaseScript {
  string public constant ZERO_FEE_AGGREGATOR_ERROR =
    "SetDynamicConfig: verifier feeAggregator is zero, fees would be stranded (set ALLOW_ZERO_FEE_AGGREGATOR=true to allow)";

  /// @notice Waives the non-zero feeAggregator policy below.
  bool public allowZeroFeeAggregator;

  /// @notice Sets the waiver directly, for tests and callers that never reach `run()`.
  function setAllowZeroFeeAggregator(
    bool allowed
  ) external {
    allowZeroFeeAggregator = allowed;
  }

  /// @notice Reverts unless the feeAggregator is non-zero or the zero value is waived.
  function validateFeeAggregator(
    address feeAggregator
  ) public view {
    if (feeAggregator == address(0)) {
      require(allowZeroFeeAggregator, ZERO_FEE_AGGREGATOR_ERROR);
      console2.log(
        "  WARN verifier feeAggregator is ZERO, waived by ALLOW_ZERO_FEE_AGGREGATOR: withdrawals revert and fees stay stranded until it is set"
      );
    }
  }

  /// @notice True when the verifier's on-chain DynamicConfig already equals `desired`.
  function isCurrent(
    address verifier,
    CommitteeVerifier.DynamicConfig memory desired
  ) public view returns (bool) {
    CommitteeVerifier.DynamicConfig memory live = CommitteeVerifier(verifier).getDynamicConfig();
    return live.feeAggregator == desired.feeAggregator && live.allowlistAdmin == desired.allowlistAdmin;
  }

  /// @notice True when applying `desired` would clear a non-zero on-chain allowlistAdmin.
  /// @dev Zero is a legitimate "no admin" state, so this warns rather than refuses. Once
  ///      applied, config and chain agree on zero and DriftCheck cannot flag it.
  function clearsAllowlistAdmin(
    address verifier,
    CommitteeVerifier.DynamicConfig memory desired
  ) public view returns (bool) {
    return
      desired.allowlistAdmin == address(0)
        && CommitteeVerifier(verifier).getDynamicConfig().allowlistAdmin != address(0);
  }

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
    allowZeroFeeAggregator = vm.envOr("ALLOW_ZERO_FEE_AGGREGATOR", false);

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

    // Before the isCurrent skip: an invalid config is a config error, not a no-op.
    validateFeeAggregator(verifierRoles.feeAggregator);

    CommitteeVerifier.DynamicConfig memory desired = toDynamicConfig(verifierRoles);
    if (isCurrent(verifier, desired)) {
      console2.log("  dynamic config UNCHANGED: on-chain already matches config, nothing staged");
    } else {
      if (clearsAllowlistAdmin(verifier, desired)) {
        console2.log("  WARN ******************************************************************");
        console2.log("  WARN allowlistAdmin is ZERO in config: this call CLEARS the on-chain allowlistAdmin");
        console2.log(
          "  WARN   on-chain allowlistAdmin now:", CommitteeVerifier(verifier).getDynamicConfig().allowlistAdmin
        );
        console2.log("  WARN   set roles.allowlistAdmin in the operator file to keep that admin");
        console2.log("  WARN ******************************************************************");
      }
      _stage(callFor(verifier, desired));
    }
    // Always flush: on a no-op this removes any stale batch left by an earlier run.
    _flush(string.concat("set-dynamic-config-", ConfigLib.tagToString(versionTag)));
  }
}
