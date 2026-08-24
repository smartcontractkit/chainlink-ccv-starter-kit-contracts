// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {
  SignatureQuorumValidator
} from "@chainlink/contracts-ccip/contracts/ccvs/components/SignatureQuorumValidator.sol";
import {console2} from "forge-std/console2.sol";

/// @title ApplySignatureConfigs
/// @notice Sets the signer set + threshold per source chain on the
///         CommitteeVerifier.
/// @dev This is a FULL-SET REPLACEMENT: the contract clears the
///      existing signer set for that source and re-adds `signers`.
/// Usage (chainAlias is the lane's DESTINATION chain — signatures are verified there):
///   OUTPUT_MODE=SAFE forge script script/configure/ApplySignatureConfigs.s.sol \
///     --sig "run(string)" base_sepolia   # (EOA path: OUTPUT_MODE=EOA + --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --aws)
contract ApplySignatureConfigs is BaseScript {
  /// @notice Which deployment a lane's signature config targets. TODO: Single point to flip
  ///         if the confirmed direction is source-side instead of dest-side.
  function _targetAlias(
    Types.LaneConfig memory lane
  ) internal pure returns (string memory) {
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
  function toSignatureConfig(
    Types.LaneConfig memory lane
  ) public pure returns (SignatureQuorumValidator.SignatureConfig[] memory configs) {
    configs = new SignatureQuorumValidator.SignatureConfig[](1);
    configs[0] = SignatureQuorumValidator.SignatureConfig({
      sourceChainSelector: lane.source.chainSelector,
      threshold: lane.signatureConfig.threshold,
      signers: lane.signatureConfig.signers
    });
  }

  /// @notice Resolves one lane to the calls `run()` stages. Requires a deployment record
  ///         for the target chain.
  /// @return calls One applySignatureConfigs call.
  /// @return targetAlias The chain the calls are addressed to (dest side).
  function laneCalls(
    Types.LaneConfig memory lane
  ) public view returns (Call[] memory calls, string memory targetAlias) {
    targetAlias = _targetAlias(lane);
    Types.Deployment memory deployment = ConfigLib.readDeployment(targetAlias);
    require(
      deployment.verifier != address(0), string.concat("ApplySignatureConfigs: verifier not recorded for ", targetAlias)
    );

    _assertValidConfig(lane);

    return (callsFor(deployment.verifier, new uint64[](0), toSignatureConfig(lane)), targetAlias);
  }

  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);

    string[] memory lanePaths = ConfigLib.listLanes();
    uint256 staged;

    for (uint256 i; i < lanePaths.length; ++i) {
      Types.LaneConfig memory lane = ConfigLib.readLaneByPath(lanePaths[i]);
      if (!_stringsEqual(_targetAlias(lane), chainAlias)) continue;

      (Call[] memory calls, string memory targetAlias) = laneCalls(lane);

      console2.log("[ApplySignatureConfigs] lane:", lane.name);
      console2.log("  target chain:", targetAlias);
      console2.log("  target verifier:", calls[0].to);
      console2.log("  source selector:", lane.source.chainSelector);
      console2.log("  threshold / signers:", lane.signatureConfig.threshold, lane.signatureConfig.signers.length);

      _stageMany(calls);
      ++staged;
    }

    require(staged > 0, string.concat("ApplySignatureConfigs: no lanes with destination ", chainAlias));
    _flush(string.concat("apply-signature-configs-", chainAlias));
  }

  // ---------------------------------------------------------------------------
  //  validation (mirror the contract's hard rules; warn on committee policy)
  // ---------------------------------------------------------------------------
  function _assertValidConfig(
    Types.LaneConfig memory lane
  ) internal pure {
    address[] memory signers = lane.signatureConfig.signers;
    uint8 threshold = lane.signatureConfig.threshold;
    uint256 signerCount = signers.length;

    // Hard rules (would revert onchain anyway; fail fast with a clearer message).
    require(signerCount > 0, "ApplySignatureConfigs: empty signer set");
    require(
      threshold >= 1 && threshold <= signerCount, "ApplySignatureConfigs: threshold must be in [1, signers.length]"
    );
    for (uint256 i; i < signerCount; ++i) {
      require(signers[i] != address(0), "ApplySignatureConfigs: zero-address signer");
      for (uint256 j = i + 1; j < signerCount; ++j) {
        require(signers[i] != signers[j], "ApplySignatureConfigs: duplicate signer");
      }
    }

    // Committee policy (non-fatal): not 1-of-1, and threshold must exceed 2/3.
    if (signerCount == 1) {
      console2.log("  WARN 1-of-1 signer set (allowed for testing; not recommended for production)"); //TODO might want stronger guarantees than a warning in the future
    } else if (uint256(threshold) * 3 <= signerCount * 2) {
      console2.log("  WARN threshold does not exceed 2/3 of the committee (policy: e.g. 3-of-4)");
    }
  }
}
