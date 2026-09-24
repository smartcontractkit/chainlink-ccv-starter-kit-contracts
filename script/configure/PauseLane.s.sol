// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {IRouter} from "@chainlink/contracts-ccip/contracts/interfaces/IRouter.sol";
import {console2} from "forge-std/console2.sol";

/// @title PauseLane
/// @notice Pauses ONE lane's outbound traffic: zeroes `router` in the source verifier's
///         remote-chain config for the lane's destination, keeping every other field as
///         it is on-chain. Skips the call when the destination is already paused, and
///         records the pause in the lane file either way so `apply-remote-config` does
///         not undo it. Requires --rpc-url in BOTH output modes.
///
/// @dev Resume: delete `remoteChainConfig.router` from the lane file (or set the real
///      router) and run ApplyRemoteChainConfigUpdates.
///
/// Usage (the RPC is the lane's SOURCE chain):
///   OUTPUT_MODE=SAFE forge script script/configure/PauseLane.s.sol \
///     --sig "run(string)" sepolia-to-base_sepolia --rpc-url $SEPOLIA_RPC_URL
///   (EOA path: OUTPUT_MODE=EOA + --broadcast --aws)
contract PauseLane is BaseScript {
  /// @notice Single source of truth for the pause calldata.
  function callFor(
    address verifier,
    BaseVerifier.RemoteChainConfigArgs memory current
  ) public pure returns (Call memory call) {
    BaseVerifier.RemoteChainConfigArgs[] memory args = new BaseVerifier.RemoteChainConfigArgs[](1);
    args[0] = argsFor(current);
    call = Call({to: verifier, value: 0, data: abi.encodeCall(CommitteeVerifier.applyRemoteChainConfigUpdates, (args))});
  }

  /// @notice The on-chain config with only the router zeroed.
  /// @dev The contract has no partial update: every field is rewritten, so the values come
  ///      from the chain, not the lane file. A pause must not smuggle in config changes.
  function argsFor(
    BaseVerifier.RemoteChainConfigArgs memory current
  ) public pure returns (BaseVerifier.RemoteChainConfigArgs memory args) {
    require(current.remoteChainSelector != 0, "PauseLane: destination is not configured on this verifier");
    require(current.gasForVerification != 0, "PauseLane: destination is not configured on this verifier");
    args = current;
    args.router = IRouter(address(0));
  }

  /// @notice True when outbound to `destChainSelector` already reverts: router zero, or
  ///         never configured.
  function isPaused(
    address verifier,
    uint64 destChainSelector
  ) public view returns (bool) {
    return address(_currentConfig(verifier, destChainSelector).router) == address(0);
  }

  function run(
    string calldata laneName
  ) external {
    Types.LaneConfig memory lane = ConfigLib.readLane(laneName);
    string memory chainAlias = lane.source.aliasName;
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    address verifier = ConfigLib.verifierByTag(deployment, lane.versionTag);
    _assertReachable(verifier, "verifier");

    console2.log("[PauseLane] lane:", laneName);
    console2.log("  source chain / verifier:", chainAlias, verifier);
    console2.log("  dest selector:", lane.dest.chainSelector);

    BaseVerifier.RemoteChainConfigArgs memory current = _currentConfig(verifier, lane.dest.chainSelector);
    if (address(current.router) == address(0)) {
      if (current.gasForVerification == 0) {
        console2.log("[PauseLane] destination never configured on this verifier: outbound already rejects");
      } else {
        console2.log("[PauseLane] already paused on-chain: router is zero");
      }
    } else {
      console2.log("[PauseLane] STAGED: router", address(current.router), "-> 0");
      _stage(callFor(verifier, current));
      _flush(string.concat("pause-lane-", laneName));
    }

    recordPause(ConfigLib.lanePath(laneName), lane.remote.router);
  }

  /// @notice Writes `remoteChainConfig.router = 0x0` into the lane file unless it already
  ///         says so. `currentRouter` is the value the file resolves to today.
  function recordPause(
    string memory path,
    address currentRouter
  ) public {
    if (currentRouter == address(0) && vm.keyExistsJson(vm.readFile(path), ".remoteChainConfig.router")) {
      console2.log("[PauseLane] lane file already records the pause:", path);
      return;
    }
    vm.writeJson(vm.toString(address(0)), path, ".remoteChainConfig.router");
    console2.log("[PauseLane] lane file updated, router = 0x0:", path);
    console2.log("  commit it: the next apply-remote-config run reads it");
  }

  function _currentConfig(
    address verifier,
    uint64 destChainSelector
  ) private view returns (BaseVerifier.RemoteChainConfigArgs memory current) {
    // the other return values are deliberately ignored
    // forge-lint: disable-next-line(unused-return)
    (current,) = CommitteeVerifier(verifier).getRemoteChainConfig(destChainSelector);
  }
}
