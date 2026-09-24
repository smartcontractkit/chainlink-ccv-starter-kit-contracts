// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PauseLane} from "../../script/configure/PauseLane.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {IRouter} from "@chainlink/contracts-ccip/contracts/interfaces/IRouter.sol";

/// @notice Exercises the PauseLane builders against the real CommitteeVerifier (deployed by
///         the fixture, owned by this test) and the lane-file write against a scratch copy.
contract PauseLaneTest is CommitteeVerifierSetup {
  PauseLane internal script;

  uint64 internal constant DEST = 3478487238524512106;
  address internal constant ROUTER = address(0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59);
  string internal constant EXAMPLE_LANE = "config/operator/lanes/sepolia-to-base_sepolia.example.json";

  function setUp() public override {
    super.setUp();
    script = new PauseLane();
  }

  /// @dev Configures DEST on the verifier the way apply-remote-config would.
  function _configureDest(
    address router
  ) internal {
    BaseVerifier.RemoteChainConfigArgs[] memory args = new BaseVerifier.RemoteChainConfigArgs[](1);
    args[0] = BaseVerifier.RemoteChainConfigArgs({
      router: IRouter(router),
      remoteChainSelector: DEST,
      allowlistEnabled: true,
      feeUSDCents: 50,
      gasForVerification: 200000,
      payloadSizeBytes: 32
    });
    verifier.applyRemoteChainConfigUpdates(args);
  }

  function _current() internal view returns (BaseVerifier.RemoteChainConfigArgs memory cfg) {
    // the other return values are deliberately ignored
    // forge-lint: disable-next-line(unused-return)
    (cfg,) = verifier.getRemoteChainConfig(DEST);
  }

  // ---------------------------------------------------------------------------
  //  isPaused
  // ---------------------------------------------------------------------------

  function test_isPaused_trueWhenNeverConfigured() public view {
    assertTrue(script.isPaused(address(verifier), DEST), "unconfigured destination already rejects outbound");
  }

  function test_isPaused_falseWhenRouterSet() public {
    _configureDest(ROUTER);
    assertFalse(script.isPaused(address(verifier), DEST));
  }

  function test_isPaused_trueWhenRouterZero() public {
    _configureDest(address(0));
    assertTrue(script.isPaused(address(verifier), DEST));
  }

  // ---------------------------------------------------------------------------
  //  argsFor / callFor: only the router changes
  // ---------------------------------------------------------------------------

  function test_argsFor_zeroesRouterOnly() public {
    _configureDest(ROUTER);
    BaseVerifier.RemoteChainConfigArgs memory args = script.argsFor(_current());

    assertEq(address(args.router), address(0), "router zeroed");
    assertEq(args.remoteChainSelector, DEST, "selector kept");
    assertEq(args.allowlistEnabled, true, "allowlistEnabled kept");
    assertEq(args.feeUSDCents, 50, "fee kept");
    assertEq(args.gasForVerification, 200000, "gas kept");
    assertEq(args.payloadSizeBytes, 32, "payload kept");
  }

  function test_argsFor_revertsWhenNeverConfigured() public {
    BaseVerifier.RemoteChainConfigArgs memory current = _current();
    vm.expectRevert(bytes("PauseLane: destination is not configured on this verifier"));
    // the call is expected to revert, so there is no return value to use
    // forge-lint: disable-next-line(unused-return)
    script.argsFor(current);
  }

  function test_callFor_pausesAndKeepsOtherFields() public {
    _configureDest(ROUTER);

    BaseScript.Call memory call = script.callFor(address(verifier), _current());
    assertEq(call.to, address(verifier), "target is verifier");
    (bool ok,) = call.to.call(call.data); // msg.sender == owner (this test)
    assertTrue(ok, "pause call applied");

    BaseVerifier.RemoteChainConfigArgs memory cfg = _current();
    assertEq(address(cfg.router), address(0), "paused");
    assertEq(cfg.allowlistEnabled, true, "allowlistEnabled untouched");
    assertEq(cfg.feeUSDCents, 50, "fee untouched");
    assertEq(cfg.gasForVerification, 200000, "gas untouched");
    assertEq(cfg.payloadSizeBytes, 32, "payload untouched");
    assertTrue(script.isPaused(address(verifier), DEST));
  }

  // ---------------------------------------------------------------------------
  //  recordPause: the lane file carries the pause
  // ---------------------------------------------------------------------------

  /// @dev One scratch file per test: tests run in parallel and must not share a path.
  ///      Parsed with raw JSON cheatcodes, not ConfigLib, so no operator catalog is needed.
  function _scratchLane(
    string memory name,
    string memory json
  ) internal returns (string memory path) {
    path = string.concat("out/governance/zz-scratch-pause-", name, ".json");
    vm.createDir("out/governance", true);
    vm.writeFile(path, json);
  }

  function test_recordPause_overwritesExplicitRouter() public {
    string memory path = _scratchLane("explicit", vm.readFile(EXAMPLE_LANE));
    vm.writeJson(vm.toString(ROUTER), path, ".remoteChainConfig.router");

    script.recordPause(path, ROUTER);

    string memory written = vm.readFile(path);
    assertEq(vm.parseJsonAddress(written, ".remoteChainConfig.router"), address(0), "router recorded as zero");
    assertEq(vm.parseJsonUint(written, ".remoteChainConfig.gasForVerification"), 200000, "other fields untouched");
    assertEq(vm.parseJsonString(written, ".name"), "sepolia-to-base_sepolia", "rest of the file untouched");
    vm.removeFile(path);
  }

  function test_recordPause_addsRouterKeyWhenInherited() public {
    // The example lane without its router key: the inherit path.
    string memory stripped = vm.replace(
      vm.readFile(EXAMPLE_LANE),
      "\"router\": \"0x0000000000000000000000000000000000000000\",\n    \"feeUSDCents\"",
      "\"feeUSDCents\""
    );
    assertFalse(vm.keyExistsJson(stripped, ".remoteChainConfig.router"), "setup: key removed");
    string memory path = _scratchLane("inherited", stripped);

    script.recordPause(path, ROUTER);

    string memory written = vm.readFile(path);
    assertTrue(vm.keyExistsJson(written, ".remoteChainConfig.router"), "key added");
    assertEq(vm.parseJsonAddress(written, ".remoteChainConfig.router"), address(0), "explicit zero");
    vm.removeFile(path);
  }

  function test_recordPause_leavesFileAloneWhenAlreadyZero() public {
    string memory path = _scratchLane("already-zero", vm.readFile(EXAMPLE_LANE));
    string memory before = vm.readFile(path);

    script.recordPause(path, address(0));

    assertEq(vm.readFile(path), before, "byte-identical");
    vm.removeFile(path);
  }
}
