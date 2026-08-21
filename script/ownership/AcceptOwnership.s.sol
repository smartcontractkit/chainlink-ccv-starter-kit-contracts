// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {console2} from "forge-std/console2.sol";

/// @title AcceptOwnership
/// @notice Outline step 13 (accept leg). Called BY the new owner to complete a
///         two-step ownership transfer. In SAFE mode this batch must be executed
///         by the incoming owner Safe.
/// @dev Generic over target ("verifier" | "resolver").
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
    address to = _eq(target, "verifier") ? dep.verifier : _eq(target, "resolver") ? dep.resolver : address(0);
    require(to != address(0), "AcceptOwnership: target must be 'verifier' or 'resolver' and deployed");

    console2.log("[AcceptOwnership]", target, "->", to);

    _stageMany(callsFor(to));
    _flush(string.concat("b-accept-owner-", target));
  }
}
