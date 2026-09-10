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
///         Runs every lane whose SOURCE is the given chain AND whose versionTag matches the
///         given one (one verifier per run), batched into ONE call, and skips the
///         lanes already matching on-chain — so --rpc-url is required in BOTH output
///         modes.
///
/// @dev EMERGENCY LEVER: router == address(0) for a destination is the ONLY outbound
///      pause. There is no inbound halt. Setting a zero router here is legitimate and
///      only emits an informational WARN.
///
/// Usage (chainAlias is the lane's SOURCE chain — outbound gating lives there):
///   OUTPUT_MODE=SAFE forge script script/configure/ApplyRemoteChainConfigUpdates.s.sol \
///     --sig "run(string,bytes4)" sepolia 0x00010001 --rpc-url $SEPOLIA_RPC_URL
///   (EOA path: OUTPUT_MODE=EOA + --broadcast --aws)
contract ApplyRemoteChainConfigUpdates is BaseScript {
  /// @notice Which deployment a lane's remote-chain config targets: the SOURCE chain.
  function _targetAlias(
    Types.LaneConfig memory lane
  ) internal pure returns (string memory) {
    return lane.source.aliasName;
  }

  /// @notice Single source of truth for the applyRemoteChainConfigUpdates calldata.
  function callFor(
    address verifier,
    BaseVerifier.RemoteChainConfigArgs[] memory args
  ) public pure returns (Call memory call) {
    call = Call({to: verifier, value: 0, data: abi.encodeCall(CommitteeVerifier.applyRemoteChainConfigUpdates, (args))});
  }

  /// @notice Translate a lane's config-as-data into the Chainlink arg struct. The
  ///         remote chain (from the source verifier's perspective) is the lane dest.
  function toRemoteChainConfigArgs(
    Types.LaneConfig memory lane
  ) public pure returns (BaseVerifier.RemoteChainConfigArgs memory args) {
    args = BaseVerifier.RemoteChainConfigArgs({
      router: IRouter(lane.remote.router),
      remoteChainSelector: lane.dest.chainSelector,
      allowlistEnabled: lane.allowlist.allowlistEnabled,
      feeUSDCents: lane.remote.feeUSDCents,
      gasForVerification: lane.remote.gasForVerification,
      payloadSizeBytes: lane.remote.payloadSizeBytes
    });
  }

  /// @notice The args a run would stage: one entry per lane whose SOURCE is `chainAlias`
  ///         and whose tag is `versionTag`, minus the lanes already current on-chain.
  /// @dev The two filters pin exactly what verifierByTag keys on (source alias, tag), so
  ///      every matched lane resolves to the caller's `verifier` and the args go out as
  ///      ONE call. Loosen either filter and this batching stops being safe.
  /// @return args The entries to send, in lane order. Its length IS the staged count.
  /// @return matched How many lanes the filters selected, staged or not.
  function argsFor(
    Types.LaneConfig[] memory lanes,
    string memory chainAlias,
    bytes4 versionTag,
    address verifier
  ) public view returns (BaseVerifier.RemoteChainConfigArgs[] memory args, uint256 matched) {
    // Sized to the upper bound, trimmed to the staged count below.
    args = new BaseVerifier.RemoteChainConfigArgs[](lanes.length);
    uint256 staged = 0;

    for (uint256 i = 0; i < lanes.length; ++i) {
      Types.LaneConfig memory lane = lanes[i];
      if (!_stringsEqual(_targetAlias(lane), chainAlias)) continue;
      if (lane.versionTag != versionTag) continue;
      ++matched;

      _assertValidConfig(lane);

      // Every field this script writes already matches.
      if (isCurrent(verifier, lane)) {
        console2.log("[ApplyRemoteChainConfigUpdates] lane UNCHANGED:", lane.name);
        continue;
      }

      console2.log("[ApplyRemoteChainConfigUpdates] lane STAGED:", lane.name);
      console2.log("  remote (dest) selector:", lane.dest.chainSelector);
      console2.log("  router:", lane.remote.router);

      args[staged] = toRemoteChainConfigArgs(lane);
      ++staged;
    }

    // Drop the unused tail: a memory array's first word is its length, and `staged` only
    // ever shrinks it. The zero-filled tail would revert InvalidRemoteChainConfig(0).
    // solhint-disable-next-line no-inline-assembly
    assembly {
      mstore(args, staged)
    }
  }

  /// @notice The lanes with this chain as source that are pinned to `versionTag` — ONE
  ///         verifier per run. Different verifiers can have different owners, and a
  ///         Safe batch is all-or-nothing, so calls needing different
  ///         executors must never share one batch.
  function run(
    string calldata chainAlias,
    bytes4 versionTag
  ) external {
    require(versionTag != bytes4(0), "ApplyRemoteChainConfigUpdates: versionTag cannot be zero");
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    address verifier = ConfigLib.verifierByTag(deployment, versionTag);
    _assertReachable(verifier, "verifier");

    console2.log("[ApplyRemoteChainConfigUpdates] target chain:", chainAlias);
    console2.log("  target verifier:", verifier);

    (BaseVerifier.RemoteChainConfigArgs[] memory args, uint256 matched) =
      argsFor(ConfigLib.readLanes(), chainAlias, versionTag, verifier);

    require(
      matched > 0,
      string.concat(
        "ApplyRemoteChainConfigUpdates: no lanes with source ",
        chainAlias,
        " pinned to versionTag ",
        ConfigLib.tagToString(versionTag)
      )
    );
    if (args.length == 0) {
      console2.log("[ApplyRemoteChainConfigUpdates] nothing to do: every lane is already current:", matched);
      return;
    }
    console2.log("[ApplyRemoteChainConfigUpdates] staged lanes:", args.length, "of", matched);
    _stage(callFor(verifier, args));

    // The tag is part of the batch name: per-tag runs on the same chain must not
    // overwrite each other's Safe batch.
    _flush(string.concat("apply-remote-chain-config-", chainAlias, "-", ConfigLib.tagToString(versionTag)));
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
      // the other return values are deliberately ignored
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
