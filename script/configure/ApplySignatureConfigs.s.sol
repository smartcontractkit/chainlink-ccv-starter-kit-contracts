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
///         Runs every lane whose DESTINATION is the given chain AND whose versionTag matches
///         the given one (one verifier per run), batched into ONE call, and skips
///         the lanes already matching on-chain — so --rpc-url is required in BOTH output
///         modes.
///
/// @dev This is a FULL-SET REPLACEMENT: the contract clears the
///      existing signer set for that source and re-adds `signers`.
///
/// Usage (chainAlias is the lane's DESTINATION chain — signatures are verified there):
///   OUTPUT_MODE=SAFE forge script script/configure/ApplySignatureConfigs.s.sol \
///     --sig "run(string,bytes4)" base_sepolia 0x00010001 --rpc-url $BASE_SEPOLIA_RPC_URL
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
  function callFor(
    address verifier,
    uint64[] memory removals,
    SignatureQuorumValidator.SignatureConfig[] memory configs
  ) public pure returns (Call memory call) {
    call = Call({
      to: verifier, value: 0, data: abi.encodeCall(SignatureQuorumValidator.applySignatureConfigs, (removals, configs))
    });
  }

  /// @notice Translate a lane's config-as-data into the Chainlink arg struct.
  function toSignatureConfig(
    Types.LaneConfig memory lane
  ) public pure returns (SignatureQuorumValidator.SignatureConfig memory config) {
    config = SignatureQuorumValidator.SignatureConfig({
      sourceChainSelector: lane.source.chainSelector,
      threshold: lane.signatureConfig.threshold,
      signers: lane.signatureConfig.signers
    });
  }

  /// @notice The configs a run would stage: one entry per lane whose DESTINATION is
  ///         `chainAlias` and whose tag is `versionTag`, minus lanes already current.
  /// @dev The two filters pin exactly what verifierByTag keys on (dest alias, tag), so
  ///      every matched lane resolves to the caller's `verifier` and the configs go out
  ///      as ONE call. Loosen either filter and this batching stops being safe.
  /// @return configs The entries to send, in lane order. Its length IS the staged count.
  /// @return matched How many lanes the filters selected, staged or not.
  function configsFor(
    Types.LaneConfig[] memory lanes,
    string memory chainAlias,
    bytes4 versionTag,
    address verifier
  ) public view returns (SignatureQuorumValidator.SignatureConfig[] memory configs, uint256 matched) {
    // Sized to the upper bound, trimmed to the staged count below.
    configs = new SignatureQuorumValidator.SignatureConfig[](lanes.length);
    uint256 staged = 0;

    for (uint256 i = 0; i < lanes.length; ++i) {
      Types.LaneConfig memory lane = lanes[i];
      if (!_stringsEqual(_targetAlias(lane), chainAlias)) continue;
      if (lane.versionTag != versionTag) continue;
      ++matched;

      // Before the isCurrent skip: an invalid config is a config error, not a no-op.
      _assertValidConfig(lane);

      if (isCurrent(verifier, lane)) {
        console2.log("[ApplySignatureConfigs] lane UNCHANGED:", lane.name);
        continue;
      }

      console2.log("[ApplySignatureConfigs] lane STAGED:", lane.name);
      console2.log("  source selector:", lane.source.chainSelector);
      console2.log("  threshold / signers:", lane.signatureConfig.threshold, lane.signatureConfig.signers.length);

      configs[staged] = toSignatureConfig(lane);
      ++staged;
    }

    // Drop the unused tail: a memory array's first word is its length, and `staged` only
    // ever shrinks it. The zero-filled tail would revert InvalidSignatureConfig.
    // solhint-disable-next-line no-inline-assembly
    assembly {
      mstore(configs, staged)
    }
  }

  /// @notice The lanes with this chain as destination that are pinned to `versionTag` —
  ///         ONE verifier per run. Different verifiers can have different owners,
  ///         and a Safe batch is all-or-nothing, so calls needing different
  ///         executors must never share one batch.
  function run(
    string calldata chainAlias,
    bytes4 versionTag
  ) external {
    require(versionTag != bytes4(0), "ApplySignatureConfigs: versionTag cannot be zero");
    _initOutput(chainAlias);
    allowWeakCommittee = vm.envOr("ALLOW_WEAK_COMMITTEE", false);

    address verifier = ConfigLib.verifierByTag(ConfigLib.readDeployment(chainAlias), versionTag);
    _assertReachable(verifier, "verifier");

    console2.log("[ApplySignatureConfigs] target chain:", chainAlias);
    console2.log("  target verifier:", verifier);

    (SignatureQuorumValidator.SignatureConfig[] memory configs, uint256 matched) =
      configsFor(ConfigLib.readLanes(), chainAlias, versionTag, verifier);

    require(
      matched > 0,
      string.concat(
        "ApplySignatureConfigs: no lanes with destination ",
        chainAlias,
        " pinned to versionTag ",
        ConfigLib.tagToString(versionTag)
      )
    );
    if (configs.length == 0) {
      console2.log("[ApplySignatureConfigs] nothing to do: every lane is already current:", matched);
      return;
    }
    console2.log("[ApplySignatureConfigs] staged lanes:", configs.length, "of", matched);
    _stage(callFor(verifier, new uint64[](0), configs));

    // The tag is part of the batch name: per-tag runs on the same chain must not
    // overwrite each other's Safe batch.
    _flush(string.concat("apply-signature-configs-", chainAlias, "-", ConfigLib.tagToString(versionTag)));
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
    for (uint256 i = 0; i < lane.signatureConfig.signers.length; ++i) {
      bool found = false;
      for (uint256 j = 0; j < signers.length; ++j) {
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
    for (uint256 i = 0; i < signerCount; ++i) {
      require(signers[i] != address(0), "ApplySignatureConfigs: zero-address signer");
      for (uint256 j = i + 1; j < signerCount; ++j) {
        require(signers[i] != signers[j], "ApplySignatureConfigs: duplicate signer");
      }
    }

    // Committee policy: threshold < signers.length (N-of-N halts the lane when one signer is
    // offline; 1-of-1 is the degenerate case) and threshold must exceed 2/3. Together these
    // make 3-of-4 the smallest compliant committee. Fatal unless explicitly waived.
    if (signerCount == 1) {
      require(
        allowWeakCommittee,
        "ApplySignatureConfigs: 1-of-1 signer set (set ALLOW_WEAK_COMMITTEE=true for test committees)"
      );
      console2.log("  WARN 1-of-1 signer set, waived by ALLOW_WEAK_COMMITTEE");
    } else if (threshold == signerCount) {
      require(
        allowWeakCommittee,
        "ApplySignatureConfigs: N-of-N committee halts on one offline signer (set ALLOW_WEAK_COMMITTEE=true)"
      );
      console2.log("  WARN N-of-N committee, waived by ALLOW_WEAK_COMMITTEE");
    } else if (uint256(threshold) * 3 <= signerCount * 2) {
      require(
        allowWeakCommittee,
        "ApplySignatureConfigs: threshold must exceed 2/3 of the committee (set ALLOW_WEAK_COMMITTEE=true)"
      );
      console2.log("  WARN threshold does not exceed 2/3, waived by ALLOW_WEAK_COMMITTEE");
    }
  }
}
