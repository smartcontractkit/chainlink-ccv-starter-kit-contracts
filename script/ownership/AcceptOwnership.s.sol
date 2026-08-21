// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {console2} from "forge-std/console2.sol";

/// @title AcceptOwnership
/// @notice Called BY the pending owner to complete a two-step ownership transfer.
///         Each party prepares its own leg: this script is run by the INCOMING holder
///         with their own SAFE_ADDRESS (or key), never generated on their behalf by
///         the proposer.
/// @dev Generic over target ("verifier" | "resolver" | "factory"). The factory leg
///      completes the transfer BootstrapFactory proposes; until it runs, the deployer
///      key keeps the factory (and with it the CREATE2 allowlist).
/// @dev Needs no roles file: acceptance is authorised by msg.sender being the pending
///      holder, not by an address in config.
///
/// Usage:
///   OUTPUT_MODE=SAFE SAFE_ADDRESS=0x<incomingOwnerSafe> forge script script/ownership/AcceptOwnership.s.sol \
///     --sig "run(string,string)" sepolia verifier
contract AcceptOwnership is BaseScript {
  function callsFor(
    address to
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({to: to, value: 0, data: abi.encodeWithSignature("acceptOwnership()")});
  }

  function run(
    string calldata chainAlias,
    string calldata target
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    address to = ConfigLib.targetAddress(dep, target);
    require(to != address(0), string.concat("AcceptOwnership: ", target, " not recorded for ", chainAlias));

    console2.log("[AcceptOwnership]", target, "->", to);

    _stageMany(callsFor(to));
    _flush(string.concat("b-accept-owner-", target));
  }
}
