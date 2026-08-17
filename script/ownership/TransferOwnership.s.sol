// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";

/// @title TransferOwnership
/// @notice Outline step 13 (propose leg). Two-step ownable: the CURRENT owner
///         proposes the transfer; the new owner accepts separately (AcceptOwnership).
/// @dev Generic over target ("verifier" | "resolver"). New owner is read from
///      config/roles/<alias>.json. Uses encodeWithSignature so no ownable interface
///      import is needed.
/// @dev HANDOVER ORDER: grant-new-before-revoke-old; only revoke the old holder
///      AFTER on-chain acceptance is confirmed. See Handover.s.sol for the full
///      three-ceremony orchestration with ordered a-/b-/c- batches.
///
/// Usage:
///   OUTPUT_MODE=SAFE SAFE_ADDRESS=0x... forge script script/ownership/TransferOwnership.s.sol \
///     --sig "run(string,string)" sepolia verifier
contract TransferOwnership is BaseScript {
 
  function callsFor(address to, address newOwner) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({to: to, value: 0, data: abi.encodeWithSignature("transferOwnership(address)", newOwner)});
  }

  function run(string calldata chainAlias, string calldata target) external {
    _initOutput();

    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);

    (address to, address newOwner) = _target(dep, roles, target);
    require(to != address(0), "TransferOwnership: target address unset");
    require(newOwner != address(0), "TransferOwnership: new owner role unset");

    console2.log("[TransferOwnership]", target);
    console2.log("  target:", to);
    console2.log("  newOwner:", newOwner);

    _stageMany(callsFor(to, newOwner));
    _flush(string.concat("a-transfer-owner-", target));
  }

  function _target(Types.Deployment memory dep, Types.RolesConfig memory roles, string calldata target)
    private
    pure
    returns (address to, address newOwner)
  {
    if (_eq(target, "verifier")) return (dep.verifier, roles.verifier.owner);
    if (_eq(target, "resolver")) return (dep.resolver, roles.resolver.owner);
    revert("TransferOwnership: target must be 'verifier' or 'resolver'");
  }
}