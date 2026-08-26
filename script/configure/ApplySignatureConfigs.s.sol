// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {
  SignatureQuorumValidator
} from "@chainlink/contracts-ccip/contracts/ccvs/components/SignatureQuorumValidator.sol";
import {console2} from "forge-std/console2.sol";

/// @title ApplySignatureConfigs
/// @notice Sets the signer set + threshold per source chain on the CommitteeVerifier.
///         Runs every lane whose DESTINATION is the given chain, one call each, and skips
///         the lanes already matching on-chain — so --rpc-url is required in BOTH output
///         modes.
///
/// @dev This is a FULL-SET REPLACEMENT: the contract clears the
///      existing signer set for that source and re-adds `signers`.
///
/// Usage (chainAlias is the lane's DESTINATION chain — signatures are verified there):
///   OUTPUT_MODE=SAFE forge script script/configure/ApplySignatureConfigs.s.sol \
///     --sig "run(string)" base_sepolia --rpc-url $BASE_SEPOLIA_RPC_URL
///   (EOA path: OUTPUT_MODE=EOA + --broadcast --aws)
contract ApplySignatureConfigs is BaseScript {
  /// @notice Waives the committee-strength policy below. `run()` sets it from
  ///         ALLOW_WEAK_COMMITTEE; callers and tests set it directly.
  bool public allowWeakCommittee;

  /// @notice Sets the waiver directly, for tests and callers that never reach `run()`.
  function setAllowWeakCommittee(
    bool allowed
  ) external {
    allowWeakCommittee = allowed;
  }

  /// @notice Which deployment a lane's signature config targets: the DEST chain.
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
    allowWeakCommittee = vm.envOr("ALLOW_WEAK_COMMITTEE", false);

    string[] memory lanePaths = ConfigLib.listLanes();
    uint256 matched;
    uint256 staged;

    for (uint256 i; i < lanePaths.length; ++i) {
      Types.LaneConfig memory lane = ConfigLib.readLaneByPath(lanePaths[i]);
      if (!_stringsEqual(_targetAlias(lane), chainAlias)) continue;
      ++matched;

      (Call[] memory calls, string memory targetAlias) = laneCalls(lane);

      // The diff reads the verifier, so an unreachable one must fail with a legible
      // reason rather than as a bare revert inside the getter.
      require(calls[0].to.code.length != 0, "ApplySignatureConfigs: no code at recorded verifier (wrong --rpc-url?)");
      if (isCurrent(calls[0].to, lane)) {
        console2.log("[ApplySignatureConfigs] lane UNCHANGED:", lane.name);
        continue;
      }

      console2.log("[ApplySignatureConfigs] lane STAGED:", lane.name);
      console2.log("  target chain:", targetAlias);
      console2.log("  target verifier:", calls[0].to);
      console2.log("  source selector:", lane.source.chainSelector);
      console2.log("  threshold / signers:", lane.signatureConfig.threshold, lane.signatureConfig.signers.length);

      _stageMany(calls);
      ++staged;
    }

    require(matched > 0, string.concat("ApplySignatureConfigs: no lanes with destination ", chainAlias));
    if (staged == 0) {
      console2.log("[ApplySignatureConfigs] nothing to do: every lane is already current:", matched);
      return;
    }
    console2.log("[ApplySignatureConfigs] staged lanes:", staged, "of", matched);
    _flush(string.concat("apply-signature-configs-", chainAlias));
  }

  /// @notice True when the config already matches on-chain: the verifier holds this
  ///         lane's signer set and threshold for its source chain.
  /// @dev Set comparison, not sequence: `applySignatureConfigs` replaces the whole set,
  ///      and the contract does not preserve the order the signers were submitted in.
  function isCurrent(
    address verifier,
    Types.LaneConfig memory lane
  ) public view returns (bool) {
    (address[] memory signers, uint8 threshold) =
      CommitteeVerifier(verifier).getSignatureConfig(lane.source.chainSelector);
    if (threshold != lane.signatureConfig.threshold) return false;
    if (signers.length != lane.signatureConfig.signers.length) return false;
    for (uint256 i; i < lane.signatureConfig.signers.length; ++i) {
      bool found;
      for (uint256 j; j < signers.length; ++j) {
        if (lane.signatureConfig.signers[i] == signers[j]) {
          found = true;
          break;
        }
      }
      if (!found) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  //  validation (mirror the contract's hard rules; warn on committee policy)
  // ---------------------------------------------------------------------------
  function _assertValidConfig(
    Types.LaneConfig memory lane
  ) internal view {
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

    // Committee policy: not 1-of-1, and threshold must exceed 2/3. Fatal unless explicitly waived.
    if (signerCount == 1) {
      require(
        allowWeakCommittee,
        "ApplySignatureConfigs: 1-of-1 signer set (set ALLOW_WEAK_COMMITTEE=true for test committees)"
      );
      console2.log("  WARN 1-of-1 signer set, waived by ALLOW_WEAK_COMMITTEE");
    } else if (uint256(threshold) * 3 <= signerCount * 2) {
      require(
        allowWeakCommittee,
        "ApplySignatureConfigs: threshold must exceed 2/3 of the committee (set ALLOW_WEAK_COMMITTEE=true)"
      );
      console2.log("  WARN threshold does not exceed 2/3, waived by ALLOW_WEAK_COMMITTEE");
    }
  }
}
