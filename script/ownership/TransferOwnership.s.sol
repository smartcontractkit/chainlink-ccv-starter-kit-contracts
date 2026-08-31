// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {IOwnable} from "@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol";
import {console2} from "forge-std/console2.sol";

/// @title TransferOwnership
/// @notice Outline step 13 (propose leg). Two-step ownable: the CURRENT owner
///         proposes the transfer; the new owner accepts separately (AcceptOwnership).
/// @dev Generic over target ("verifier" | "resolver" | "factory"). New owner is read from
///      config/roles/<alias>.json.
/// @dev HANDOVER ORDER: grant-new-before-revoke-old; only revoke the old holder
///      AFTER on-chain acceptance is confirmed (DriftCheck goes clean on the new owner).
///      The accept leg is prepared and executed by the incoming holder, not here.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/ownership/TransferOwnership.s.sol \
///     --sig "run(string,string)" sepolia verifier
contract TransferOwnership is BaseScript {
  function callsFor(
    address to,
    address newOwner
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({to: to, value: 0, data: abi.encodeCall(IOwnable.transferOwnership, (newOwner))});
  }

  function run(
    string calldata chainAlias,
    string calldata target
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);

    address to = ConfigLib.targetAddress(deployment, target);
    address newOwner = ConfigLib.targetOwner(roles, target);
    require(to != address(0), string.concat("TransferOwnership: ", target, " not recorded for ", chainAlias));
    require(newOwner != address(0), string.concat("TransferOwnership: ", target, " owner role unset"));

    console2.log("[TransferOwnership]", target);
    console2.log("  target:", to);
    console2.log("  newOwner:", newOwner);

    _stageMany(callsFor(to, newOwner));
    _flush(string.concat("transfer-owner-", target));
  }
}
