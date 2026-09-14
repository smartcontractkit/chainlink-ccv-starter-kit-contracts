// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AddressSetLib} from "../../src/lib/AddressSetLib.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {console2} from "forge-std/console2.sol";

/// @title ApplyAllowlistUpdates
/// @notice Reconciles the sender allowlist per destination on the CommitteeVerifier with
///         `allowlist.allowedSenders` in each lane file, the desired FULL set.
///         Runs every lane whose SOURCE is the given chain AND whose versionTag matches the
///         given one (one verifier per run), batched into ONE call. Each entry carries only
///         the delta (removes + adds) against the current on-chain set, and lanes already
///         matching are skipped — so --rpc-url is required in BOTH output modes.
///         Caller may be EITHER the owner or the DynamicConfig.allowlistAdmin — the
///         contract accepts both (else reverts OnlyCallableByOwnerOrAllowlistAdmin).
///
/// @dev Contract rules mirrored in _assertValidConfig:
///        - Adding senders requires allowlistEnabled == true, else InvalidAllowListRequest.
///        - Added senders must be non-zero, else InvalidAllowListRequest.
///        - Removals always apply, so a disabled lane with `allowedSenders: []` also
///          clears any residual members.
///
/// Usage (chainAlias is the lane's SOURCE chain — sender gating lives there):
///   OUTPUT_MODE=SAFE forge script script/configure/ApplyAllowlistUpdates.s.sol \
///     --sig "run(string,bytes4)" sepolia 0x00010001 --rpc-url $SEPOLIA_RPC_URL
///   (EOA path: OUTPUT_MODE=EOA + --broadcast --aws)
contract ApplyAllowlistUpdates is BaseScript {
  using AddressSetLib for address[];

  /// @notice Which deployment a lane's allowlist config targets: the SOURCE chain.
  function _targetAlias(
    Types.LaneConfig memory lane
  ) internal pure returns (string memory) {
    return lane.source.aliasName;
  }

  /// @notice Single source of truth for the applyAllowlistUpdates calldata.
  function callFor(
    address verifier,
    BaseVerifier.AllowlistConfigArgs[] memory args
  ) public pure returns (Call memory call) {
    call = Call({to: verifier, value: 0, data: abi.encodeCall(CommitteeVerifier.applyAllowlistUpdates, (args))});
  }

  /// @notice Translate a lane's desired set into the Chainlink delta struct, keyed by the
  ///         lane's destination selector.
  /// @param current The senders currently allowlisted on-chain for that destination.
  function toAllowlistConfigArgs(
    Types.LaneConfig memory lane,
    address[] memory current
  ) public pure returns (BaseVerifier.AllowlistConfigArgs memory args) {
    (address[] memory removes, address[] memory adds) = current.diff(lane.allowlist.allowedSenders);
    args = BaseVerifier.AllowlistConfigArgs({
      destChainSelector: lane.dest.chainSelector,
      allowlistEnabled: lane.allowlist.allowlistEnabled,
      addedAllowlistedSenders: adds,
      removedAllowlistedSenders: removes
    });
  }

  /// @notice The args a run would stage: one entry per lane whose SOURCE is `chainAlias`
  ///         and whose tag is `versionTag`, minus the lanes already current on-chain.
  /// @return args The entries to send, in lane order. Its length IS the staged count.
  /// @return matched How many lanes the filters selected, staged or not.
  function argsFor(
    Types.LaneConfig[] memory lanes,
    string memory chainAlias,
    bytes4 versionTag,
    address verifier
  ) public view returns (BaseVerifier.AllowlistConfigArgs[] memory args, uint256 matched) {
    // Sized to the upper bound, trimmed to the staged count below.
    args = new BaseVerifier.AllowlistConfigArgs[](lanes.length);
    uint256 staged = 0;

    for (uint256 i = 0; i < lanes.length; ++i) {
      Types.LaneConfig memory lane = lanes[i];
      if (!_stringsEqual(_targetAlias(lane), chainAlias)) continue;
      if (lane.versionTag != versionTag) continue;
      ++matched;

      // Before the isCurrent skip: an invalid config is a config error, not a no-op.
      _assertValidConfig(lane);

      (BaseVerifier.RemoteChainConfigArgs memory remote, address[] memory current) =
        CommitteeVerifier(verifier).getRemoteChainConfig(lane.dest.chainSelector);
      BaseVerifier.AllowlistConfigArgs memory entry = toAllowlistConfigArgs(lane, current);
      // The call writes the flag too, so an empty delta with a differing flag still stages.
      if (
        remote.allowlistEnabled == lane.allowlist.allowlistEnabled && entry.addedAllowlistedSenders.length == 0
          && entry.removedAllowlistedSenders.length == 0
      ) {
        console2.log("[ApplyAllowlistUpdates] lane UNCHANGED:", lane.name);
        continue;
      }

      console2.log("[ApplyAllowlistUpdates] lane STAGED:", lane.name);
      console2.log("  dest selector:", lane.dest.chainSelector);
      console2.log("  allowlistEnabled:", lane.allowlist.allowlistEnabled);
      console2.log("  desired size:", lane.allowlist.allowedSenders.length, "on-chain size:", current.length);
      for (uint256 j = 0; j < entry.removedAllowlistedSenders.length; ++j) {
        console2.log("  REMOVE:", entry.removedAllowlistedSenders[j]);
      }
      for (uint256 j = 0; j < entry.addedAllowlistedSenders.length; ++j) {
        console2.log("  ADD:   ", entry.addedAllowlistedSenders[j]);
      }

      args[staged] = entry;
      ++staged;
    }

    // Drop the unused tail: a memory array's first word is its length, and `staged` only
    // ever shrinks it. The zero-filled tail would apply a meaningless entry for selector 0.
    // solhint-disable-next-line no-inline-assembly
    assembly {
      mstore(args, staged)
    }
  }

  /// @notice The lanes with this chain as source that are pinned to `versionTag` — ONE
  ///         verifier per run. Different verifiers can have different owners/allowlist
  ///         admins, and a Safe batch is all-or-nothing, so calls
  ///         needing different executors must never share one batch.
  function run(
    string calldata chainAlias,
    bytes4 versionTag
  ) external {
    require(versionTag != bytes4(0), "ApplyAllowlistUpdates: versionTag cannot be zero");
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    address verifier = ConfigLib.verifierByTag(deployment, versionTag);
    _assertReachable(verifier, "verifier");

    console2.log("[ApplyAllowlistUpdates] target chain:", chainAlias);
    console2.log("  target verifier:", verifier);

    (BaseVerifier.AllowlistConfigArgs[] memory args, uint256 matched) =
      argsFor(ConfigLib.readLanes(), chainAlias, versionTag, verifier);

    require(
      matched > 0,
      string.concat(
        "ApplyAllowlistUpdates: no lanes with source ",
        chainAlias,
        " pinned to versionTag ",
        ConfigLib.tagToString(versionTag)
      )
    );
    if (args.length == 0) {
      console2.log("[ApplyAllowlistUpdates] nothing to do: every lane is already current:", matched);
      return;
    }
    console2.log("[ApplyAllowlistUpdates] staged lanes:", args.length, "of", matched);
    _stage(callFor(verifier, args));

    // The tag is part of the batch name: per-tag runs on the same chain must not
    // overwrite each other's Safe batch.
    _flush(string.concat("apply-allowlist-updates-", chainAlias, "-", ConfigLib.tagToString(versionTag)));
  }

  /// @notice True when the config already matches on-chain: the flag matches and the
  ///         on-chain senders equal `allowedSenders` as a set, order ignored.
  function isCurrent(
    address verifier,
    Types.LaneConfig memory lane
  ) public view returns (bool) {
    (BaseVerifier.RemoteChainConfigArgs memory remote, address[] memory senders) =
      CommitteeVerifier(verifier).getRemoteChainConfig(lane.dest.chainSelector);
    return remote.allowlistEnabled == lane.allowlist.allowlistEnabled && senders.sameSet(lane.allowlist.allowedSenders);
  }

  // ---------------------------------------------------------------------------
  //  validation (mirror the contract's hard rules)
  // ---------------------------------------------------------------------------
  function _assertValidConfig(
    Types.LaneConfig memory lane
  ) internal pure {
    require(lane.dest.chainSelector != 0, "ApplyAllowlistUpdates: destChainSelector cannot be zero");
    address[] memory senders = lane.allowlist.allowedSenders;
    if (senders.length > 0) {
      require(lane.allowlist.allowlistEnabled, "ApplyAllowlistUpdates: allowedSenders requires allowlistEnabled=true");
    }
    for (uint256 i = 0; i < senders.length; ++i) {
      require(senders[i] != address(0), "ApplyAllowlistUpdates: zero-address sender in allowedSenders");
      for (uint256 j = i + 1; j < senders.length; ++j) {
        require(senders[i] != senders[j], "ApplyAllowlistUpdates: duplicate sender in allowedSenders");
      }
    }
  }
}
