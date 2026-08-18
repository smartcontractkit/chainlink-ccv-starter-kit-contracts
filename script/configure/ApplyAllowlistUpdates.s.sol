// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";

/// @title ApplyAllowlistUpdates
/// @notice Sender allowlist per destination on the CommitteeVerifier.
///
/// @dev Caller must be the owner OR the DynamicConfig.allowlistAdmin (contract allows
///      both; otherwise reverts OnlyCallableByOwnerOrAllowlistAdmin).
///
/// @dev Contract rules mirrored in _assertValidConfig:
///        - Adding senders requires allowlistEnabled == true, else InvalidAllowListRequest.
///        - Added senders must be non-zero, else InvalidAllowListRequest.
///        - Removals always apply (no-op if the sender wasn't present).
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/ApplyAllowlistUpdates.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL   # (EOA path: OUTPUT_MODE=EOA + --broadcast --aws)
///   NOTE: in SAFE mode the batch must be signed by the owner OR allowlistAdmin Safe.
contract ApplyAllowlistUpdates is BaseScript {
  /// @notice Which deployment a lane's allowlist config targets. TODO Single point to flip
  ///         if the confirmed direction is dest-side instead of source-side.
  function _targetAlias(Types.LaneConfig memory lane) internal pure returns (string memory) {
    return lane.source.aliasName;
  }

  /// @notice Single source of truth for the applyAllowlistUpdates calldata.
  function callsFor(address verifier, BaseVerifier.AllowlistConfigArgs[] memory args)
    public
    pure
    returns (Call[] memory calls)
  {
    calls = new Call[](1);
    calls[0] = Call({
      to: verifier,
      value: 0,
      data: abi.encodeWithSelector(CommitteeVerifier.applyAllowlistUpdates.selector, args)
    });
  }

  /// @notice Translate a lane's config-as-data into the Chainlink arg struct, keyed by
  ///         the lane's destination selector.
  function toAllowlistConfigArgs(Types.LaneConfig memory lane)
    public
    pure
    returns (BaseVerifier.AllowlistConfigArgs[] memory args)
  {
    args = new BaseVerifier.AllowlistConfigArgs[](1);
    args[0] = BaseVerifier.AllowlistConfigArgs({
      destChainSelector: lane.dest.chainSelector,
      allowlistEnabled: lane.allowlist.allowlistEnabled,
      addedAllowlistedSenders: lane.allowlist.added,
      removedAllowlistedSenders: lane.allowlist.removed
    });
  }

  function run() external {
    _initOutput();

    string[] memory lanes = ConfigLib.listLanes();
    require(lanes.length > 0, "ApplyAllowlistUpdates: no lane configs found in config/lanes/");

    for (uint256 i; i < lanes.length; ++i) {
      Types.LaneConfig memory lane = ConfigLib.readLaneByPath(lanes[i]);
      string memory targetAlias = _targetAlias(lane);
      Types.Deployment memory dep = ConfigLib.readDeployment(targetAlias);
      require(
        dep.verifier != address(0),
        string.concat("ApplyAllowlistUpdates: verifier not recorded for ", targetAlias)
      );

      _assertValidConfig(lane);

      console2.log("[ApplyAllowlistUpdates] lane:", lane.name);
      console2.log("  target verifier:", dep.verifier);
      console2.log("  dest selector:", lane.dest.chainSelector);
      console2.log("  enabled / added / removed:", lane.allowlist.allowlistEnabled);
      console2.log("    added:", lane.allowlist.added.length, "removed:", lane.allowlist.removed.length);

      _stageMany(callsFor(dep.verifier, toAllowlistConfigArgs(lane)));
    }

    _flush("c-apply-allowlist-updates");
  }

  // ---------------------------------------------------------------------------
  //  validation (mirror the contract's hard rules)
  // ---------------------------------------------------------------------------
  function _assertValidConfig(Types.LaneConfig memory lane) internal pure {
    require(lane.dest.chainSelector != 0, "ApplyAllowlistUpdates: destChainSelector cannot be zero");

    Types.AllowlistConfig memory al = lane.allowlist;
    if (al.added.length > 0) {
      require(al.allowlistEnabled, "ApplyAllowlistUpdates: adding senders requires allowlistEnabled=true");
      for (uint256 i; i < al.added.length; ++i) {
        require(al.added[i] != address(0), "ApplyAllowlistUpdates: zero-address sender in adds");
      }
    }
  }
}