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

    (BaseVerifier.RemoteChainConfigArgs memory cfg,) = verifier.getRemoteChainConfig(DEST);
    assertEq(address(cfg.router), address(0), "router should be zero (paused)");
  }

  function test_reverts_whenGasForVerificationIsZero() public {
    // Contract reverts DestGasCannotBeZero.
    assertFalse(_applyRemoteChainConfig(ROUTER, 0), "should have reverted on-chain");
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
