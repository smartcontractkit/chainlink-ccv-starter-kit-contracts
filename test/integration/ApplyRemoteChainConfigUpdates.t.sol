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

  // Fuji selector (matches the staging config) used as the remote (dest) chain.
  uint64 internal constant DEST = 14767482510784806043;
  address internal constant ROUTER = address(0x784d49a71BB4C48eB7dA4cD7e6Ecb424f9b5EAB1);

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
    BaseScript.Call[] memory calls =
      script.callsFor(address(verifier), _buildRemoteChainConfigArgs(router, gasForVerification));
    assertEq(calls.length, 1, "one call expected");
    assertEq(calls[0].to, address(verifier), "target is verifier");
    (ok,) = calls[0].to.call(calls[0].data); // msg.sender == owner (this test)
  }

  function test_callsFor_setsRemoteChainConfig() public {
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
    Types.LaneConfig memory lane = ConfigLib.readLaneByPath("config/lanes/sepolia-to-base_sepolia.example.json");
    BaseVerifier.RemoteChainConfigArgs[] memory args = script.toRemoteChainConfigArgs(lane);

    assertEq(args.length, 1);
    assertEq(args[0].remoteChainSelector, lane.dest.chainSelector, "remote selector = lane dest");
    assertEq(address(args[0].router), lane.remote.router, "router");
    assertEq(args[0].gasForVerification, 200000, "gas from example lane");
  }
}
