// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ApplyRemoteChainConfigUpdates} from "../../script/configure/ApplyRemoteChainConfigUpdates.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {IRouter} from "@chainlink/contracts-ccip/contracts/interfaces/IRouter.sol";

/// @notice Exercises the ApplyRemoteChainConfigUpdates builder against the real
///         audited CommitteeVerifier (deployed by the fixture, owned by this test).
contract ApplyRemoteChainConfigUpdatesTest is CommitteeVerifierSetup {
  ApplyRemoteChainConfigUpdates internal script;

  // Local chain Sepolia, remote (dest) Arbitrum Sepolia on a CCIP v2 lane.
  // RemoteChainConfig.router is the LOCAL (Sepolia) router the verifier resolves the OnRamp from.
  uint64 internal constant DEST = 3478487238524512106;
  address internal constant ROUTER = address(0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59);

  function setUp() public override {
    super.setUp();
    script = new ApplyRemoteChainConfigUpdates();
  }

  function _buildRemoteChainConfigArgs(
    address router,
    uint32 gasForVerification
  ) internal pure returns (BaseVerifier.RemoteChainConfigArgs[] memory args) {
    args = new BaseVerifier.RemoteChainConfigArgs[](1);
    args[0] = BaseVerifier.RemoteChainConfigArgs({
      router: IRouter(router),
      remoteChainSelector: DEST,
      allowlistEnabled: false,
      feeUSDCents: 50,
      gasForVerification: gasForVerification,
      payloadSizeBytes: 0
    });
  }

  function _applyRemoteChainConfig(
    address router,
    uint32 gasForVerification
  ) internal returns (bool ok) {
    BaseScript.Call memory call =
      script.callFor(address(verifier), _buildRemoteChainConfigArgs(router, gasForVerification));
    assertEq(call.to, address(verifier), "target is verifier");
    (ok,) = call.to.call(call.data); // msg.sender == owner (this test)
  }

  function test_callFor_setsRemoteChainConfig() public {
    assertTrue(_applyRemoteChainConfig(ROUTER, 200000), "apply failed");

    // the other return values are deliberately ignored
    // forge-lint: disable-next-line(unused-return)
    (BaseVerifier.RemoteChainConfigArgs memory cfg,) = verifier.getRemoteChainConfig(DEST);
    assertEq(address(cfg.router), ROUTER, "router");
    assertEq(cfg.remoteChainSelector, DEST, "remote selector");
    assertEq(cfg.gasForVerification, 200000, "gas");
    assertEq(cfg.feeUSDCents, 50, "fee");
    assertEq(cfg.allowlistEnabled, false, "allowlist");
  }

  function test_routerZero_pausesOutbound() public {
    // router == 0 is the outbound emergency lever and is a valid on-chain state.
    assertTrue(_applyRemoteChainConfig(address(0), 200000), "pause apply failed");

    // the other return values are deliberately ignored
    // forge-lint: disable-next-line(unused-return)
    (BaseVerifier.RemoteChainConfigArgs memory cfg,) = verifier.getRemoteChainConfig(DEST);
    assertEq(address(cfg.router), address(0), "router should be zero (paused)");
  }

  function test_reverts_whenGasForVerificationIsZero() public {
    // Contract reverts DestGasCannotBeZero.
    assertFalse(_applyRemoteChainConfig(ROUTER, 0), "should have reverted on-chain");
  }

  // ---- isCurrent: what keeps a re-run from restaging applied lanes ----
  // Every field this script writes has to participate, or a real change reads as
  // "already current" and is silently dropped from the batch.

  /// @dev Lane matching what `_applyRemoteChainConfig(ROUTER, 200000)` writes.
  function _lane() internal pure returns (Types.LaneConfig memory lane) {
    lane.name = "test-lane";
    lane.dest.chainSelector = DEST;
    lane.remote.router = ROUTER;
    lane.remote.feeUSDCents = 50;
    lane.remote.gasForVerification = 200000;
    lane.remote.payloadSizeBytes = 0;
    lane.allowlist.allowlistEnabled = false;
  }

  function test_isCurrent_falseBeforeAnythingIsApplied() public view {
    assertFalse(script.isCurrent(address(verifier), _lane()), "unconfigured destination is not current");
  }

  function test_isCurrent_trueAfterApplyingTheSameValues() public {
    assertTrue(_applyRemoteChainConfig(ROUTER, 200000), "apply failed");
    assertTrue(script.isCurrent(address(verifier), _lane()), "identical config is current");
  }

  function test_isCurrent_falseWhenRouterDiffers() public {
    assertTrue(_applyRemoteChainConfig(ROUTER, 200000), "apply failed");
    Types.LaneConfig memory lane = _lane();
    lane.remote.router = address(0xD1FF);
    assertFalse(script.isCurrent(address(verifier), lane), "router change must stage");
  }

  function test_isCurrent_falseWhenGasForVerificationDiffers() public {
    assertTrue(_applyRemoteChainConfig(ROUTER, 200000), "apply failed");
    Types.LaneConfig memory lane = _lane();
    lane.remote.gasForVerification = 300000;
    assertFalse(script.isCurrent(address(verifier), lane), "gas change must stage");
  }

  function test_isCurrent_falseWhenFeeDiffers() public {
    assertTrue(_applyRemoteChainConfig(ROUTER, 200000), "apply failed");
    Types.LaneConfig memory lane = _lane();
    lane.remote.feeUSDCents = 51;
    assertFalse(script.isCurrent(address(verifier), lane), "fee change must stage");
  }

  function test_isCurrent_falseWhenAllowlistEnabledDiffers() public {
    assertTrue(_applyRemoteChainConfig(ROUTER, 200000), "apply failed");
    Types.LaneConfig memory lane = _lane();
    lane.allowlist.allowlistEnabled = true;
    assertFalse(script.isCurrent(address(verifier), lane), "allowlistEnabled is written by this call too");
  }

  function test_toRemoteChainConfigArgs_translatesExampleLane() public view {
    Types.LaneConfig memory lane =
      ConfigLib.readLaneByPath("config/operator/lanes/sepolia-to-base_sepolia.example.json");
    BaseVerifier.RemoteChainConfigArgs memory args = script.toRemoteChainConfigArgs(lane);

    assertEq(args.remoteChainSelector, lane.dest.chainSelector, "remote selector = lane dest");
    assertEq(address(args.router), lane.remote.router, "router");
    assertEq(args.gasForVerification, 200000, "gas from example lane");
  }

  // ---------------------------------------------------------------------------
  //  argsFor: selection, skip and ordering across a lane set
  // ---------------------------------------------------------------------------

  string internal constant SRC_ALIAS = "zz-scratch-src-chain";

  function _selectableLane(
    string memory sourceAlias,
    uint64 destSelector,
    bytes4 tag
  ) internal pure returns (Types.LaneConfig memory lane) {
    // An unconfigured destination is never current, so these lanes are selectable.
    lane = _lane();
    lane.source.aliasName = sourceAlias;
    lane.dest.chainSelector = destSelector;
    lane.versionTag = tag;
  }

  function _oneLane(
    Types.LaneConfig memory lane
  ) internal pure returns (Types.LaneConfig[] memory lanes) {
    lanes = new Types.LaneConfig[](1);
    lanes[0] = lane;
  }

  function test_argsFor_skipsLanesFromAnotherChain() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](2);
    lanes[0] = _selectableLane(SRC_ALIAS, DEST, VERSION_TAG);
    lanes[1] = _selectableLane("zz-scratch-other-chain", 999, VERSION_TAG);

    (BaseVerifier.RemoteChainConfigArgs[] memory args, uint256 matched) =
      script.argsFor(lanes, SRC_ALIAS, VERSION_TAG, address(verifier));

    assertEq(matched, 1, "only the lane sourced on this chain matched");
    assertEq(args.length, 1);
    assertEq(args[0].remoteChainSelector, DEST);
  }

  function test_argsFor_skipsLanesPinnedToAnotherTag() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](2);
    lanes[0] = _selectableLane(SRC_ALIAS, DEST, VERSION_TAG);
    lanes[1] = _selectableLane(SRC_ALIAS, 999, VERSION_TAG_V2);

    (BaseVerifier.RemoteChainConfigArgs[] memory args, uint256 matched) =
      script.argsFor(lanes, SRC_ALIAS, VERSION_TAG, address(verifier));

    assertEq(matched, 1, "the other tag is a different verifier's business");
    assertEq(args.length, 1);
  }

  /// @dev The array length IS the staged count: the over-allocated tail must not survive.
  function test_argsFor_lengthIsTheStagedCount() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](4);
    lanes[0] = _selectableLane(SRC_ALIAS, 111, VERSION_TAG);
    lanes[1] = _selectableLane("zz-scratch-other-chain", 222, VERSION_TAG);
    lanes[2] = _selectableLane(SRC_ALIAS, 333, VERSION_TAG);
    lanes[3] = _selectableLane(SRC_ALIAS, 444, VERSION_TAG_V2);

    (BaseVerifier.RemoteChainConfigArgs[] memory args, uint256 matched) =
      script.argsFor(lanes, SRC_ALIAS, VERSION_TAG, address(verifier));

    assertEq(matched, 2, "two lanes matched the filters");
    assertEq(args.length, 2, "trimmed from the 4-slot upper bound");
    assertEq(args[0].remoteChainSelector, 111, "lane order preserved");
    assertEq(args[1].remoteChainSelector, 333, "lane order preserved");
  }

  /// @dev A lane already applied on-chain counts as matched but must not be staged.
  function test_argsFor_skipsLaneAlreadyCurrentButStillCountsIt() public {
    assertTrue(_applyRemoteChainConfig(ROUTER, 200000), "setup: apply failed");
    Types.LaneConfig memory lane = _selectableLane(SRC_ALIAS, DEST, VERSION_TAG);
    assertTrue(script.isCurrent(address(verifier), lane), "setup: now current");

    (BaseVerifier.RemoteChainConfigArgs[] memory args, uint256 matched) =
      script.argsFor(_oneLane(lane), SRC_ALIAS, VERSION_TAG, address(verifier));

    assertEq(matched, 1, "the lane still matched the filters");
    assertEq(args.length, 0, "but nothing to stage");
  }

  /// @dev The point of batching: two matched lanes become ONE call that applies both.
  function test_batchedCall_appliesEveryMatchedLaneInOneCall() public {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](2);
    lanes[0] = _selectableLane(SRC_ALIAS, 111, VERSION_TAG);
    lanes[1] = _selectableLane(SRC_ALIAS, 222, VERSION_TAG);

    (BaseVerifier.RemoteChainConfigArgs[] memory args, uint256 matched) =
      script.argsFor(lanes, SRC_ALIAS, VERSION_TAG, address(verifier));
    assertEq(matched, 2);
    assertEq(args.length, 2, "both lanes staged");

    BaseScript.Call memory call = script.callFor(address(verifier), args);
    (bool ok,) = call.to.call(call.data);
    assertTrue(ok, "the single batched call applied");

    assertTrue(script.isCurrent(address(verifier), lanes[0]), "remote 111 configured");
    assertTrue(script.isCurrent(address(verifier), lanes[1]), "remote 222 configured");
  }
}
