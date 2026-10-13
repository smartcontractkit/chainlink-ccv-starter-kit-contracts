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
/// @dev A zero feeAggregator is fatal unless ALLOW_ZERO_FEE_AGGREGATOR=true: the resolver
///      keeps accruing fees while every withdrawal reverts, so they are stranded until an
///      owner-gated fix lands.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/SetFeeAggregator.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
contract SetFeeAggregator is BaseScript {
  string public constant ZERO_FEE_AGGREGATOR_ERROR =
    "SetFeeAggregator: resolver feeAggregator is zero, fees would be stranded (set ALLOW_ZERO_FEE_AGGREGATOR=true to allow)";

  /// @notice Waives the non-zero feeAggregator policy below.
  bool public allowZeroFeeAggregator;

  /// @notice Sets the waiver directly, for tests and callers that never reach `run()`.
  function setAllowZeroFeeAggregator(
    bool allowed
  ) external {
    allowZeroFeeAggregator = allowed;
  }

  /// @notice Reverts unless the feeAggregator is non-zero or the zero value is waived.
  function validateFeeAggregator(
    address feeAggregator
  ) public view {
    if (feeAggregator == address(0)) {
      require(allowZeroFeeAggregator, ZERO_FEE_AGGREGATOR_ERROR);
      console2.log(
        "  WARN resolver feeAggregator is ZERO, waived by ALLOW_ZERO_FEE_AGGREGATOR: withdrawals revert and fees stay stranded until it is set"
      );
    }
  }

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
    allowZeroFeeAggregator = vm.envOr("ALLOW_ZERO_FEE_AGGREGATOR", false);

    Types.OperatorConfig memory operator = ConfigLib.readOperator(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    require(
      deployment.resolver != address(0), string.concat("SetFeeAggregator: resolver not recorded for ", chainAlias)
    );

    console2.log("[SetFeeAggregator] chain:", chainAlias);
    console2.log("  target resolver:", deployment.resolver);
    console2.log("  feeAggregator:", operator.resolver.roles.feeAggregator);

    validateFeeAggregator(operator.resolver.roles.feeAggregator);

    _stage(callFor(deployment.resolver, operator.resolver.roles.feeAggregator));
    _flush("set-fee-aggregator-resolver");
  }
}
