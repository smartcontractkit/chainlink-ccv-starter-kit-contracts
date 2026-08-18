// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {SignatureQuorumValidator} from "@chainlink/contracts-ccip/contracts/ccvs/components/SignatureQuorumValidator.sol";

/// @title ApplySignatureConfigs
/// @notice Sets the signer set + threshold per source chain on the
///         CommitteeVerifier.
/// @dev This is a FULL-SET REPLACEMENT: the contract clears the
///      existing signer set for that source and re-adds `signers`.
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/ApplySignatureConfigs.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL   # (EOA path: OUTPUT_MODE=EOA + --broadcast --aws)
contract ApplySignatureConfigs is BaseScript {
  /// @notice Which deployment a lane's signature config targets. TODO: Single point to flip
  ///         if the confirmed direction is source-side instead of dest-side.
  function _targetAlias(Types.LaneConfig memory lane) internal pure returns (string memory) {
    return lane.dest.aliasName;
  }

  /// @notice Single source of truth for the applySignatureConfigs calldata.
  /// @param verifier The CommitteeVerifier to configure.
  /// @param removals Source chain selectors whose config should be cleared (usually empty).
  /// @param configs  The desired signer configs to set (full-set replacement per source).
  function callsFor(
    address verifier,
    uint64[] memory removals,
    SignatureQuorumValidator.SignatureConfig[] memory configs
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({
      to: verifier,
      value: 0,
      data: abi.encodeWithSelector(SignatureQuorumValidator.applySignatureConfigs.selector, removals, configs)
    });
  }

  /// @notice Translate a lane's config-as-data into the Chainlink arg struct.
  function toSignatureConfig(Types.LaneConfig memory lane)
    public
    pure
    returns (SignatureQuorumValidator.SignatureConfig[] memory configs)
  {
    configs = new SignatureQuorumValidator.SignatureConfig[](1);
    configs[0] = SignatureQuorumValidator.SignatureConfig({
      sourceChainSelector: lane.source.chainSelector,
      threshold: lane.sig.threshold,
      signers: lane.sig.signers
    });
  }

  function run() external {
    _initOutput();

    string[] memory lanes = ConfigLib.listLanes();
    require(lanes.length > 0, "ApplySignatureConfigs: no lane configs found in config/lanes/");

    for (uint256 i; i < lanes.length; ++i) {
      Types.LaneConfig memory lane = ConfigLib.readLaneByPath(lanes[i]);
      string memory targetAlias = _targetAlias(lane);
      Types.Deployment memory dep = ConfigLib.readDeployment(targetAlias);
      require(dep.verifier != address(0), string.concat("ApplySignatureConfigs: verifier not recorded for ", targetAlias));

      _assertValidConfig(lane);

      console2.log("[ApplySignatureConfigs] lane:", lane.name);
      console2.log("  target verifier:", dep.verifier);
      console2.log("  source selector:", lane.source.chainSelector);
      console2.log("  threshold / signers:", lane.sig.threshold, lane.sig.signers.length);

      _stageMany(callsFor(dep.verifier, new uint64[](0), toSignatureConfig(lane)));
    }

    _flush("a-apply-signature-configs");
  }

  // ---------------------------------------------------------------------------
  //  validation (mirror the contract's hard rules; warn on committee policy)
  // ---------------------------------------------------------------------------
  function _assertValidConfig(Types.LaneConfig memory lane) internal pure {
    address[] memory signers = lane.sig.signers;
    uint8 threshold = lane.sig.threshold;
    uint256 n = signers.length;

    // Hard rules (would revert onchain anyway; fail fast with a clearer message).
    require(n > 0, "ApplySignatureConfigs: empty signer set");
    require(threshold >= 1 && threshold <= n, "ApplySignatureConfigs: threshold must be in [1, signers.length]");
    for (uint256 i; i < n; ++i) {
      require(signers[i] != address(0), "ApplySignatureConfigs: zero-address signer");
      for (uint256 j = i + 1; j < n; ++j) {
        require(signers[i] != signers[j], "ApplySignatureConfigs: duplicate signer");
      }
    }

    // Committee policy (non-fatal): not 1-of-1, and threshold must exceed 2/3.
    if (n == 1) {
      console2.log("  WARN 1-of-1 signer set (allowed for testing; not recommended for production)"); //TODO might want stronger guarantees than a warning in the future
    } else if (uint256(threshold) * 3 <= n * 2) {
      console2.log("  WARN threshold does not exceed 2/3 of the committee (policy: e.g. 3-of-4)");
    }
  }
}