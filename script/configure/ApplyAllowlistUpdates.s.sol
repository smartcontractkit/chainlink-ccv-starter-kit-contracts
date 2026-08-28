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
///         Runs every lane whose SOURCE is the given chain, one call each, and skips the
///         lanes already matching on-chain — so --rpc-url is required in BOTH output
///         modes.
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
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
///   (EOA path: OUTPUT_MODE=EOA + --broadcast --aws)
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
    calls[0] = Call({to: verifier, value: 0, data: abi.encodeCall(CommitteeVerifier.applyAllowlistUpdates, (args))});
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
    // The diff below reads the verifier, so an unreachable one must fail here with a
    // legible reason rather than as a bare revert inside the first getter call.
    require(
      deployment.verifier.code.length != 0, "ApplyAllowlistUpdates: no code at recorded verifier (wrong --rpc-url?)"
    );

    string[] memory lanePaths = ConfigLib.listLanes();
    uint256 matched = 0;
    uint256 staged = 0;

    for (uint256 i = 0; i < lanePaths.length; ++i) {
      Types.LaneConfig memory lane = ConfigLib.readLaneByPath(lanePaths[i]);
      if (!_stringsEqual(_targetAlias(lane), chainAlias)) continue;
      ++matched;
      _assertValidConfig(lane);

      if (isCurrent(deployment.verifier, lane)) {
        console2.log("[ApplyAllowlistUpdates] lane UNCHANGED:", lane.name);
        continue;
      }

      console2.log("[ApplyAllowlistUpdates] lane STAGED:", lane.name);
      console2.log("  target verifier:", deployment.verifier);
      console2.log("  dest selector:", lane.dest.chainSelector);
      console2.log("  allowlistEnabled:", lane.allowlist.allowlistEnabled);
      console2.log("    added:", lane.allowlist.added.length, "removed:", lane.allowlist.removed.length);

      _stageMany(callsFor(deployment.verifier, toAllowlistConfigArgs(lane)));
      ++staged;
    }

    require(matched > 0, string.concat("ApplyAllowlistUpdates: no lanes with source ", chainAlias));
    if (staged == 0) {
      console2.log("[ApplyAllowlistUpdates] nothing to do: every lane is already current:", matched);
      return;
    }
    console2.log("[ApplyAllowlistUpdates] staged lanes:", staged, "of", matched);
    _flush(string.concat("apply-allowlist-updates-", chainAlias));
  }

  /// @notice True when the config already matches on-chain: the flag matches, every
  ///         `added` sender is present, and no `removed` sender is.
  function isCurrent(
    address verifier,
    Types.LaneConfig memory lane
  ) public view returns (bool) {
    (BaseVerifier.RemoteChainConfigArgs memory remote, address[] memory senders) =
      CommitteeVerifier(verifier).getRemoteChainConfig(lane.dest.chainSelector);
    if (remote.allowlistEnabled != lane.allowlist.allowlistEnabled) return false;
    for (uint256 i = 0; i < lane.allowlist.added.length; ++i) {
      if (!_contains(senders, lane.allowlist.added[i])) return false;
    }
    for (uint256 i = 0; i < lane.allowlist.removed.length; ++i) {
      if (_contains(senders, lane.allowlist.removed[i])) return false;
    }
    return true;
  }

  function _contains(
    address[] memory haystack,
    address needle
  ) private pure returns (bool) {
    for (uint256 i = 0; i < haystack.length; ++i) {
      if (haystack[i] == needle) return true;
    }
    return false;
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
      for (uint256 i = 0; i < allowlist.added.length; ++i) {
        require(allowlist.added[i] != address(0), "ApplyAllowlistUpdates: zero-address sender in adds");
      }
    }
  }
}
