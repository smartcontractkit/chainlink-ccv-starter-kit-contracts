// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {console2} from "forge-std/console2.sol";

/// @title ApplyAllowlistUpdates
/// @notice Sender allowlist per destination on the CommitteeVerifier.
///         Caller may be EITHER the owner or the DynamicConfig.allowlistAdmin — the
///         contract accepts both (else reverts OnlyCallableByOwnerOrAllowlistAdmin).
///
/// @dev Contract rules mirrored in _assertValidConfig:
///        - Adding senders requires allowlistEnabled == true, else InvalidAllowListRequest.
///        - Added senders must be non-zero, else InvalidAllowListRequest.
///        - Removals always apply (no-op if the sender wasn't present).
///
/// Usage (chainAlias is the lane's SOURCE chain — sender gating lives there):
///   OUTPUT_MODE=SAFE forge script script/configure/ApplyAllowlistUpdates.s.sol \
///     --sig "run(string)" sepolia   # (EOA path: OUTPUT_MODE=EOA + --rpc-url $SEPOLIA_RPC_URL --broadcast --aws)
contract ApplyAllowlistUpdates is BaseScript {
  /// @notice Which deployment a lane's allowlist config targets: the SOURCE chain.
  function _targetAlias(
    Types.LaneConfig memory lane
  ) internal pure returns (string memory) {
    return lane.source.aliasName;
  }

  /// @notice Single source of truth for the applyAllowlistUpdates calldata.
  function callsFor(
    address verifier,
    BaseVerifier.AllowlistConfigArgs[] memory args
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({
      to: verifier, value: 0, data: abi.encodeWithSelector(CommitteeVerifier.applyAllowlistUpdates.selector, args)
    });
  }

  /// @notice Translate a lane's config-as-data into the Chainlink arg struct, keyed by
  ///         the lane's destination selector.
  function toAllowlistConfigArgs(
    Types.LaneConfig memory lane
  ) public pure returns (BaseVerifier.AllowlistConfigArgs[] memory args) {
    args = new BaseVerifier.AllowlistConfigArgs[](1);
    args[0] = BaseVerifier.AllowlistConfigArgs({
      destChainSelector: lane.dest.chainSelector,
      allowlistEnabled: lane.allowlist.allowlistEnabled,
      addedAllowlistedSenders: lane.allowlist.added,
      removedAllowlistedSenders: lane.allowlist.removed
    });
  }

  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    require(
      deployment.verifier != address(0), string.concat("ApplyAllowlistUpdates: verifier not recorded for ", chainAlias)
    );

    string[] memory lanePaths = ConfigLib.listLanes();
    uint256 staged;

    for (uint256 i; i < lanePaths.length; ++i) {
      Types.LaneConfig memory lane = ConfigLib.readLaneByPath(lanePaths[i]);
      console2.log("[ApplyAllowlistUpdates] lane src alias:", lane.source.aliasName);
      if (!_stringsEqual(_targetAlias(lane), chainAlias)) continue;
      _assertValidConfig(lane);

      console2.log("[ApplyAllowlistUpdates] lane:", lane.name);
      console2.log("  target verifier:", deployment.verifier);
      console2.log("  dest selector:", lane.dest.chainSelector);
      console2.log("  enabled / added / removed:", lane.allowlist.allowlistEnabled);
      console2.log("    added:", lane.allowlist.added.length, "removed:", lane.allowlist.removed.length);

      _stageMany(callsFor(deployment.verifier, toAllowlistConfigArgs(lane)));
      ++staged;
    }

    require(staged > 0, string.concat("ApplyAllowlistUpdates: no lanes with source ", chainAlias));
    _flush(string.concat("apply-allowlist-updates-", chainAlias));
  }

  // ---------------------------------------------------------------------------
  //  validation (mirror the contract's hard rules)
  // ---------------------------------------------------------------------------
  function _assertValidConfig(
    Types.LaneConfig memory lane
  ) internal pure {
    require(lane.dest.chainSelector != 0, "ApplyAllowlistUpdates: destChainSelector cannot be zero");
    Types.AllowlistConfig memory allowlist = lane.allowlist;
    if (allowlist.added.length > 0) {
      require(allowlist.allowlistEnabled, "ApplyAllowlistUpdates: adding senders requires allowlistEnabled=true");
      for (uint256 i; i < allowlist.added.length; ++i) {
        require(allowlist.added[i] != address(0), "ApplyAllowlistUpdates: zero-address sender in adds");
      }
    }
  }
}
