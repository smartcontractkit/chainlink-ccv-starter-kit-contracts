// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {IRouter} from "@chainlink/contracts-ccip/contracts/interfaces/IRouter.sol";
import {console2} from "forge-std/console2.sol";

/// @title ApplyRemoteChainConfigUpdates
/// @notice Per destination: local router + verification fee + gas +
///         payload size + allowlist toggle on the CommitteeVerifier.
///         Runs every lane whose SOURCE is the given chain, one call each, and skips the
///         lanes already matching on-chain — so --rpc-url is required in BOTH output
///         modes.
///
/// @dev EMERGENCY LEVER: router == address(0) for a destination is the ONLY outbound
///      pause. There is no inbound halt. Setting a zero router here is legitimate and
///      only emits an informational WARN.
///
/// Usage (chainAlias is the lane's SOURCE chain — outbound gating lives there):
///   OUTPUT_MODE=SAFE forge script script/configure/ApplyRemoteChainConfigUpdates.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
///   (EOA path: OUTPUT_MODE=EOA + --broadcast --aws)
contract ApplyRemoteChainConfigUpdates is BaseScript {
  /// @notice Which deployment a lane's remote-chain config targets: the SOURCE chain.
  function _targetAlias(
    Types.LaneConfig memory lane
  ) internal pure returns (string memory) {
    return lane.source.aliasName;
  }

  /// @notice Single source of truth for the applyRemoteChainConfigUpdates calldata.
  function callsFor(
    address verifier,
    BaseVerifier.RemoteChainConfigArgs[] memory args
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({
      to: verifier,
      value: 0,
      data: abi.encodeWithSelector(CommitteeVerifier.applyRemoteChainConfigUpdates.selector, args)
    });
  }

  /// @notice Translate a lane's config-as-data into the Chainlink arg struct. The
  ///         remote chain (from the source verifier's perspective) is the lane dest.
  function toRemoteChainConfigArgs(
    Types.LaneConfig memory lane
  ) public pure returns (BaseVerifier.RemoteChainConfigArgs[] memory args) {
    args = new BaseVerifier.RemoteChainConfigArgs[](1);
    args[0] = BaseVerifier.RemoteChainConfigArgs({
      router: IRouter(lane.remote.router),
      remoteChainSelector: lane.dest.chainSelector,
      allowlistEnabled: lane.allowlist.allowlistEnabled,
      feeUSDCents: lane.remote.feeUSDCents,
      gasForVerification: lane.remote.gasForVerification,
      payloadSizeBytes: lane.remote.payloadSizeBytes
    });
  }

  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    require(
      deployment.verifier != address(0),
      string.concat("ApplyRemoteChainConfigUpdates: verifier not recorded for ", chainAlias)
    );
    // The diff below reads the verifier, so an unreachable one must fail here with a
    // legible reason rather than as a bare revert inside the first getter call.
    require(
      deployment.verifier.code.length != 0,
      "ApplyRemoteChainConfigUpdates: no code at recorded verifier (wrong --rpc-url?)"
    );

    string[] memory lanePaths = ConfigLib.listLanes();
    uint256 matched = 0;
    uint256 staged = 0;

    for (uint256 i = 0; i < lanePaths.length; ++i) {
      Types.LaneConfig memory lane = ConfigLib.readLaneByPath(lanePaths[i]);
      if (!_stringsEqual(_targetAlias(lane), chainAlias)) continue;
      ++matched;

      _assertValidConfig(lane);

      // Every field this script writes already matches.
      if (isCurrent(deployment.verifier, lane)) {
        console2.log("[ApplyRemoteChainConfigUpdates] lane UNCHANGED:", lane.name);
        continue;
      }

      console2.log("[ApplyRemoteChainConfigUpdates] lane STAGED:", lane.name);
      console2.log("  target verifier:", deployment.verifier);
      console2.log("  remote (dest) selector:", lane.dest.chainSelector);
      console2.log("  router:", lane.remote.router);

      _stageMany(callsFor(deployment.verifier, toRemoteChainConfigArgs(lane)));
      ++staged;
    }

    require(matched > 0, string.concat("ApplyRemoteChainConfigUpdates: no lanes with source ", chainAlias));
    if (staged == 0) {
      console2.log("[ApplyRemoteChainConfigUpdates] nothing to do: every lane is already current:", matched);
      return;
    }
    console2.log("[ApplyRemoteChainConfigUpdates] staged lanes:", staged, "of", matched);
    _flush(string.concat("apply-remote-chain-config-", chainAlias));
  }

  /// @notice True when the config already matches on-chain: every field this script
  ///         writes equals what the verifier holds for the lane's destination.
  /// @dev Mirrors the field set in `toRemoteChainConfigArgs`. The allowlist *senders* are
  ///      deliberately not compared: they are owned by ApplyAllowlistUpdates, and only the
  ///      `allowlistEnabled` flag is written by both.
  function isCurrent(
    address verifier,
    Types.LaneConfig memory lane
  ) public view returns (bool) {
    (
      BaseVerifier.RemoteChainConfigArgs memory remote,
      // the needed tuple element is destructured; the rest is deliberately dropped
      // forge-lint: disable-next-line(unused-return)
    ) = CommitteeVerifier(verifier).getRemoteChainConfig(lane.dest.chainSelector);
    return address(remote.router) == lane.remote.router && remote.allowlistEnabled == lane.allowlist.allowlistEnabled
      && remote.feeUSDCents == lane.remote.feeUSDCents && remote.gasForVerification == lane.remote.gasForVerification
      && remote.payloadSizeBytes == lane.remote.payloadSizeBytes;
  }

  // ---------------------------------------------------------------------------
  //  validation (mirror the contract's hard rules; warn on the pause lever)
  // ---------------------------------------------------------------------------
  function _assertValidConfig(
    Types.LaneConfig memory lane
  ) internal pure {
    require(lane.dest.chainSelector != 0, "ApplyRemoteChainConfigUpdates: remoteChainSelector cannot be zero");
    require(lane.remote.gasForVerification != 0, "ApplyRemoteChainConfigUpdates: gasForVerification cannot be zero");
    if (lane.remote.router == address(0)) {
      console2.log("  WARN router == 0: OUTBOUND PAUSED for this destination (emergency lever)");
    }
  }
}
