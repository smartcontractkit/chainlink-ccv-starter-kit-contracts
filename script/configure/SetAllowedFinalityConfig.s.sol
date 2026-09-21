// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {FinalityConfigLib} from "../../src/lib/FinalityConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {console2} from "forge-std/console2.sol";

/// @title SetAllowedFinalityConfig
/// @notice Sets the allowed finality config on the CommitteeVerifier.
///         Per verifier, not per lane.
///
/// @dev From the `allowedFinality` block of this tag's verifier entry in
///      config/operator/chains/<alias>.json, encoded by
///      FinalityConfigLib. It bounds what a SENDER may request: full finality always, a
///      safe-tag request when `allowSafeTag` is set, a depth request of at least
///      `minBlockDepth` when that is set. An empty block allows full finality only.
///
/// Usage (versionTag selects which recorded verifier to configure):
///   OUTPUT_MODE=SAFE forge script script/configure/SetAllowedFinalityConfig.s.sol \
///     --sig "run(string,bytes4)" sepolia 0x00010001 --rpc-url $SEPOLIA_RPC_URL
contract SetAllowedFinalityConfig is BaseScript {
  bytes4 public constant WAIT_FOR_FINALITY = FinalityCodec.WAIT_FOR_FINALITY_FLAG;

  string public constant WEAK_FINALITY_ERROR =
    "SetAllowedFinalityConfig: below full finality (set ALLOW_WEAK_FINALITY=true to allow a fast path)";

  /// @notice Waives the full-finality policy below.
  bool public allowWeakFinality;

  /// @notice Sets the waiver directly, for tests and callers that never reach `run()`.
  function setAllowWeakFinality(
    bool allowed
  ) external {
    allowWeakFinality = allowed;
  }

  /// @notice Reverts unless the value is permitted by policy.
  /// @dev Anything below full finality weakens the guarantee for every sender using this
  ///      verifier, so it is fatal unless explicitly waived. The encoding itself needs no
  ///      check: FinalityConfigLib cannot produce a value the codec assigns no meaning to.
  function validateFinalityPolicy(
    bytes4 allowedFinality
  ) public view {
    if (allowedFinality != WAIT_FOR_FINALITY) {
      require(allowWeakFinality, WEAK_FINALITY_ERROR);
      console2.log("  WARN not full finality (fast-path/safe finality allowed), waived by ALLOW_WEAK_FINALITY");
    }
  }

  /// @notice Single source of truth for the setAllowedFinalityConfig calldata.
  function callFor(
    address verifier,
    bytes4 allowedFinality
  ) public pure returns (Call memory call) {
    call = Call({
      to: verifier, value: 0, data: abi.encodeCall(CommitteeVerifier.setAllowedFinalityConfig, (allowedFinality))
    });
  }

  function run(
    string calldata chainAlias,
    bytes4 versionTag
  ) external {
    _initOutput(chainAlias);
    allowWeakFinality = vm.envOr("ALLOW_WEAK_FINALITY", false);

    Types.VerifierConfig memory verifierConfig =
      ConfigLib.verifierConfigByTag(ConfigLib.readOperator(chainAlias), versionTag);
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    address verifier = ConfigLib.verifierByTag(deployment, versionTag);
    _assertReachable(verifier, "verifier");
    bytes4 allowedFinality = FinalityConfigLib.encode(verifierConfig.allowedFinality);

    console2.log("[SetAllowedFinalityConfig] chain:", chainAlias);
    console2.log("  versionTag:", ConfigLib.tagToString(versionTag));
    console2.log("  target verifier:", verifier);
    console2.log("  allowedFinality:", ConfigLib.tagToString(allowedFinality));
    console2.log("    a sender may request:", FinalityConfigLib.describe(allowedFinality));

    validateFinalityPolicy(allowedFinality);

    _stage(callFor(verifier, allowedFinality));
    _flush(string.concat("set-allowed-finality-config-", ConfigLib.tagToString(versionTag)));
  }
}
