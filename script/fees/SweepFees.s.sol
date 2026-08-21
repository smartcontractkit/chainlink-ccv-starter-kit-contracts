// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {console2} from "forge-std/console2.sol";

/// @title SweepFees
/// @notice Outline step 15. Sweeps accrued fee-token balances from BOTH the verifier
///         and the resolver to their (distinct) fee aggregators.
/// @dev Target call (grounded, both contracts, permissionless):
///        withdrawFeeTokens(address[] feeTokens)  -> transfers to that contract's feeAggregator.
///      A zero feeAggregator makes the withdraw REVERT (FeeTokenHandler). This script
///      guards on the intended fee aggregator from config/roles and warns if unset;
///      you should ALSO assert the on-chain feeAggregator is non-zero before sweeping.
/// @dev Because withdrawFeeTokens is permissionless it works from an EOA directly,
///      but is routed through _stage so a Safe batch can be produced too.
contract SweepFees is BaseScript {
  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);

    // TODO(step 15): load the fee-token address list for this chain from config
    //   (add a `feeTokens` array to config/chains/<alias>.json). Empty list = no-op.
    address[] memory feeTokens = new address[](0);

    // Zero-destination guard (intended holders). Also verify on-chain before a real run.
    if (roles.verifier.feeAggregator == address(0)) {
      console2.log("[SweepFees] WARN verifier feeAggregator is zero; withdraw would revert. Skipping verifier.");
    } else if (dep.verifier != address(0)) {
      _stage(dep.verifier, abi.encodeWithSignature("withdrawFeeTokens(address[])", feeTokens));
    }

    if (roles.resolver.feeAggregator == address(0)) {
      console2.log("[SweepFees] WARN resolver feeAggregator is zero; withdraw would revert. Skipping resolver.");
    } else if (dep.resolver != address(0)) {
      _stage(dep.resolver, abi.encodeWithSignature("withdrawFeeTokens(address[])", feeTokens));
    }

    _flush("sweep-fees");
  }
}
