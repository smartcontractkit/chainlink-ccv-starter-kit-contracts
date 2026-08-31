// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {console2} from "forge-std/console2.sol";

/// @title SetAllowedFinalityConfig
/// @notice Sets the allowed finality config on the CommitteeVerifier.
///         This is PER CHAIN / per verifier (not per lane).
///
/// @dev FinalityCodec bytes4 encoding:
///        0x00000000  wait for FULL finality (safest; production default)
///        0x0000NNNN  block depth NNNN (low 16 bits) — e.g. 0x00000001 = depth-1 fast path
///        0x00010000  WAIT_FOR_SAFE flag (bit 16)
///      From config/chains/<alias>.json `finalityConfig`; bounds what a SENDER may request.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/SetAllowedFinalityConfig.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
contract SetAllowedFinalityConfig is BaseScript {
  bytes4 public constant WAIT_FOR_FINALITY = FinalityCodec.WAIT_FOR_FINALITY_FLAG;

  /// @dev Everything the codec does NOT assign: bits 17-31. A value setting them expresses
  ///      no mode that exists today. Derived so the two assigned fields stay the authority.
  bytes4 public constant RESERVED_FLAGS_MASK = ~(FinalityCodec.WAIT_FOR_SAFE_FLAG | FinalityCodec.BLOCK_DEPTH_MASK);

  string public constant RESERVED_BITS_ERROR =
    "SetAllowedFinalityConfig: finalityConfig sets reserved bits 17-31; check the encoding";
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

  /// @notice Reverts on a `finalityConfig` that FinalityCodec assigns no meaning to.
  /// @dev Only the reserved bits are checked. `allowedFinality` is deliberately allowed to
  ///      combine modes: `FinalityCodec._encodeBlockDepthAndSafeFlag` exists to produce
  ///      `WAIT_FOR_SAFE | depth`, documented as valid for ALLOWED finality though not for
  ///      a sender's REQUESTED finality.
  function validateEncoding(
    bytes4 allowedFinality
  ) public pure {
    require(allowedFinality & RESERVED_FLAGS_MASK == bytes4(0), RESERVED_BITS_ERROR);
  }

  /// @notice Reverts unless the value is well-formed AND permitted by policy.
  function validateFinalityPolicy(
    bytes4 allowedFinality
  ) public view {
    // A malformed encoding is always fatal: it cannot be what anyone intended.
    validateEncoding(allowedFinality);

    // Anything below full finality weakens the guarantee for every sender on this chain,
    // so it is fatal unless explicitly waived.
    if (allowedFinality != WAIT_FOR_FINALITY) {
      require(allowWeakFinality, WEAK_FINALITY_ERROR);
      console2.log("  WARN not full finality (fast-path/safe finality allowed), waived by ALLOW_WEAK_FINALITY");
    }
  }

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
    allowWeakFinality = vm.envOr("ALLOW_WEAK_FINALITY", false);

    Types.ChainConfig memory chainConfig = ConfigLib.readChain(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    require(
      deployment.verifier != address(0),
      string.concat("SetAllowedFinalityConfig: verifier not recorded for ", chainAlias)
    );

    console2.log("[SetAllowedFinalityConfig] chain:", chainAlias);
    console2.log("  target verifier:", deployment.verifier);
    console2.log("  finalityConfig:", vm.toString(chainConfig.finalityConfig));

    validateFinalityPolicy(chainConfig.finalityConfig);

    _stageMany(callsFor(deployment.verifier, chainConfig.finalityConfig));
    _flush("set-allowed-finality-config");
  }
}
