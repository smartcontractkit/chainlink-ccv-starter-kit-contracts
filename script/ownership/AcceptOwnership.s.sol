// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {IOwnable} from "@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol";
import {console2} from "forge-std/console2.sol";

/// @title AcceptOwnership
/// @notice Called BY the pending owner to complete a two-step ownership transfer.
///         Each party prepares its own leg: this script is run by the INCOMING holder
///         themselves, never generated on their behalf by the proposer.
/// @dev Generic over target ("verifier[:<versionTag>]" | "resolver" | "factory"). The factory leg
///      completes the transfer BootstrapFactory proposes; until it runs, the deployer
///      key keeps the factory (and with it the CREATE2 allowlist).
/// @dev Needs no roles file: acceptance is authorised by msg.sender being the pending
///      holder, not by an address in config.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/ownership/AcceptOwnership.s.sol \
///     --sig "run(string,string)" sepolia verifier
contract AcceptOwnership is BaseScript {
  function callFor(
    address to
  ) public pure returns (Call memory call) {
    call = Call({to: to, value: 0, data: abi.encodeCall(IOwnable.acceptOwnership, ())});
  }

  function run(
    string calldata chainAlias,
    string calldata target
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    address to = ConfigLib.targetAddress(deployment, target);
    // A call to a codeless address SUCCEEDS silently, hence the reachability preflight.
    _assertReachable(to, target);

    console2.log("[AcceptOwnership]", target, "->", to);

    _stage(callFor(to));
    _flush(string.concat("accept-owner-", target));
  }
}
