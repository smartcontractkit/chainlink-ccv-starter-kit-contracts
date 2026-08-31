// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {IOwnable} from "@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol";
import {console2} from "forge-std/console2.sol";

/// @title CancelOwnership
/// @notice Cancels a pending (proposed but not yet accepted) ownership transfer by
///         re-proposing address(0): Ownable2Step keeps exactly one pending owner, so
///         overwriting it with zero leaves nobody able to accept.
/// @dev Generic over target ("verifier" | "resolver" | "factory"), like TransferOwnership.
///      Executed by the CURRENT owner (onlyOwner on-chain); the zero address lives only
///      here so TransferOwnership keeps rejecting it as a proposed owner.
/// @dev Harmless when nothing is pending: the call just overwrites zero with zero.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/ownership/CancelOwnership.s.sol \
///     --sig "run(string,string)" sepolia verifier
contract CancelOwnership is BaseScript {
  function callsFor(
    address to
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({to: to, value: 0, data: abi.encodeCall(IOwnable.transferOwnership, (address(0)))});
  }

  function run(
    string calldata chainAlias,
    string calldata target
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    address to = ConfigLib.targetAddress(deployment, target);
    require(to != address(0), string.concat("CancelOwnership: ", target, " not recorded for ", chainAlias));

    console2.log("[CancelOwnership]", target);
    console2.log("  target:", to);
    console2.log("  clearing any pending owner (re-proposing address(0))");

    _stageMany(callsFor(to));
    _flush(string.concat("cancel-owner-", target));
  }
}
