// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {console2} from "forge-std/console2.sol";

/// @title SetAllowedFinalityConfig
/// @notice Sets the allowed finality config on the CommitteeVerifier.
///         This is PER CHAIN / per verifier (not per lane).
///
/// @dev FinalityCodec bytes4 encoding:
///        0x00000000  wait for FULL finality (safest; production default)
///        0x0000NNNN  block depth NNNN (low 16 bits) — e.g. 0x00000001 = depth-1 fast path
///        0x00010000  WAIT_FOR_SAFE flag (bit 16)
///      The value comes from config/chains/<alias>.json `finalityConfig`, which is
///      currently a PLACEHOLDER (0x00000001 on staging to permit fast-path test
///      messages) — TODO revisit before production.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/SetAllowedFinalityConfig.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
contract SetAllowedFinalityConfig is BaseScript {
  bytes4 internal constant WAIT_FOR_FINALITY = bytes4(0);

  /// @notice Single source of truth for the setAllowedFinalityConfig calldata.
  function callsFor(
    address verifier,
    bytes4 allowedFinality
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({
      to: verifier,
      value: 0,
      data: abi.encodeWithSelector(CommitteeVerifier.setAllowedFinalityConfig.selector, allowedFinality)
    });
  }

  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);

    Types.ChainConfig memory chainConfig = ConfigLib.readChain(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    require(
      deployment.verifier != address(0),
      string.concat("SetAllowedFinalityConfig: verifier not recorded for ", chainAlias)
    );

    console2.log("[SetAllowedFinalityConfig] chain:", chainAlias);
    console2.log("  target verifier:", deployment.verifier);
    console2.log("  finalityConfig:", vm.toString(chainConfig.finalityConfig));

    if (chainConfig.finalityConfig != WAIT_FOR_FINALITY) {
      console2.log("  WARN not full finality (fast-path/safe finality allowed) - confirm intended for this env");
    }

    _stageMany(callsFor(deployment.verifier, chainConfig.finalityConfig));
    _flush("set-allowed-finality-config");
  }
}
