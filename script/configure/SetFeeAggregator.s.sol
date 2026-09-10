// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {console2} from "forge-std/console2.sol";

/// @title SetFeeAggregator
/// @notice Sets the resolver's fee aggregator.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/SetFeeAggregator.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
contract SetFeeAggregator is BaseScript {
  /// @notice Single source of truth for the resolver setFeeAggregator calldata.
  function callFor(
    address resolver,
    address feeAggregator
  ) public pure returns (Call memory call) {
    call =
      Call({to: resolver, value: 0, data: abi.encodeCall(VersionedVerifierResolver.setFeeAggregator, (feeAggregator))});
  }

  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);

    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    require(
      deployment.resolver != address(0), string.concat("SetFeeAggregator: resolver not recorded for ", chainAlias)
    );

    console2.log("[SetFeeAggregator] chain:", chainAlias);
    console2.log("  target resolver:", deployment.resolver);
    console2.log("  feeAggregator:", roles.resolver.feeAggregator);

    if (roles.resolver.feeAggregator == address(0)) {
      console2.log("  WARN resolver feeAggregator is zero: fee withdrawals will revert until set");
    }

    _stage(callFor(deployment.resolver, roles.resolver.feeAggregator));
    _flush("set-fee-aggregator-resolver");
  }
}
