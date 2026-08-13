// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {SignatureQuorumValidator} from "@chainlink/contracts-ccip/contracts/ccvs/components/SignatureQuorumValidator.sol";

/// @title ApplySignatureConfigs
/// @notice Outline step 6. Sets the signer set + threshold per source chain.
/// @dev Target call (grounded):
///        CommitteeVerifier.applySignatureConfigs(
///          uint64[] sourceChainSelectorsToRemove,
///          SignatureConfig[] signatureConfigs   // {uint64 sourceChainSelector; uint8 threshold; address[] signers}
///        )
///      FULL-SET REPLACEMENT: build the complete desired signer set every time,
///      there is no incremental add/remove.
///      Constraint (open point 7): default must not be 1-of-1 and threshold must
///      exceed 2/3 (e.g. 10 signers -> threshold 7).
///
/// @dev DIRECTION (confirm vs Chainlink's configure_committee_verifier_for_lanes.go):
///      applied on the DEST chain's verifier, keyed by the SOURCE chain selector.
contract ApplySignatureConfigs is BaseScript {
  /// @dev exposed to keep the import used and to hand callers the exact selector.
  ///      Declared on SignatureQuorumValidator (inherited by CommitteeVerifier).
  bytes4 internal constant SELECTOR = SignatureQuorumValidator.applySignatureConfigs.selector;

  function run() external {
    _initOutput();

    string[] memory lanes = ConfigLib.listLanes();
    for (uint256 i; i < lanes.length; ++i) {
      Types.LaneConfig memory lane = ConfigLib.readLaneByPath(lanes[i]);
      Types.Deployment memory dep = ConfigLib.readDeployment(lane.dest.aliasName);

      console2.log("[ApplySignatureConfigs] lane:", lane.name);
      console2.log("  target verifier (dest):", dep.verifier);
      console2.log("  threshold:", lane.sig.threshold);

      // TODO(step 6): translate Types.SignatureConfig -> SignatureQuorumValidator.SignatureConfig[]
      //   SignatureQuorumValidator.SignatureConfig[] memory cfgs = new SignatureQuorumValidator.SignatureConfig[](1);
      //   cfgs[0] = SignatureQuorumValidator.SignatureConfig({
      //     sourceChainSelector: lane.source.chainSelector,
      //     threshold: lane.sig.threshold,
      //     signers: lane.sig.signers
      //   });
      //   (encode via the instance so the inherited fn resolves cleanly)
      //   bytes memory data = abi.encodeCall(
      //     CommitteeVerifier(dep.verifier).applySignatureConfigs, (new uint64[](0), cfgs));
      //   _stage(dep.verifier, data);
    }

    _flush("a-apply-signature-configs");
  }
}
