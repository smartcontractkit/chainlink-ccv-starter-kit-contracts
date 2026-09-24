// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {IOwnable} from "@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol";
import {console2} from "forge-std/console2.sol";

/// @title TransferOwnership
/// @notice Proposes an ownership transfer. Two-step ownable: the CURRENT owner proposes
///         here; the new owner accepts separately (AcceptOwnership).
/// @dev Generic over target ("verifier:<versionTag>" | "resolver" | "factory"); the tag
///      form selects a verifier when several are recorded. New owner is read
///      from config/operator/chains/<alias>.json.
/// @dev HANDOVER ORDER: grant-new-before-revoke-old; only revoke the old holder
///      AFTER on-chain acceptance is confirmed (DriftCheck goes clean on the new owner).
///      The accept leg is prepared and executed by the incoming holder, not here.
/// @dev Preflight reads chain state, so --rpc-url is required even in SAFE mode. In SAFE
///      mode the batch is refused unless SAFE_ADDRESS is the current on-chain owner; EOA
///      runs get the same guarantee from forge's pre-broadcast simulation reverting.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/ownership/TransferOwnership.s.sol \
///     --sig "run(string,string)" sepolia verifier:0x00010001
contract TransferOwnership is BaseScript {
  function callFor(
    address to,
    address proposedOwner
  ) public pure returns (Call memory call) {
    call = Call({to: to, value: 0, data: abi.encodeCall(IOwnable.transferOwnership, (proposedOwner))});
  }

  function run(
    string calldata chainAlias,
    string calldata target
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    Types.OperatorConfig memory operator = ConfigLib.readOperator(chainAlias);

    address to = ConfigLib.targetAddress(deployment, target);
    address proposedOwner = ConfigLib.targetOwner(operator, target);
    require(proposedOwner != address(0), string.concat("TransferOwnership: ", target, " owner role unset"));
    _assertReachable(to, target);
    // SAFE-only: EOA runs execute now, so forge's pre-broadcast simulation already
    // reverts on a non-owner sender.
    if (outputMode == OutputMode.SAFE) requireExecutorIsCurrentOwner(to, outputSafeAddress);

    console2.log("[TransferOwnership]", target);
    console2.log("  target:", to);
    console2.log("  owner PROPOSED to:", proposedOwner);
    console2.log("  (must acceptOwnership() to take effect)");

    _stage(callFor(to, proposedOwner));
    _flush(string.concat("transfer-owner-", target));
  }
}
