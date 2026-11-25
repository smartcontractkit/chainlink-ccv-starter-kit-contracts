// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLoader} from "../../script/governance/ValidateConfig.s.sol";
import {Types} from "../../src/lib/Types.sol";
import {Test} from "forge-std/Test.sol";

/// @notice ValidateConfig's offline zero-feeAggregator check, through the same loader
///         seam the script uses. `run()` itself reads only real-named files under
///         config/, which a hermetic test must not write, so the check is exercised here.
contract ValidateConfigFeeAggregatorsTest is Test {
  string internal constant OPERATOR_EXAMPLE = "config/operator/chains/sepolia.example.json";
  string internal constant VERIFIER_FEE_AGG = "0x2000000000000000000000000000000000000004";
  string internal constant RESOLVER_FEE_AGG = "0x2000000000000000000000000000000000000005";
  string internal constant ZERO = "0x0000000000000000000000000000000000000000";

  ConfigLoader internal loader;

  function setUp() public {
    loader = new ConfigLoader();
  }

  function test_exampleOperator_hasNoZeroFeeAggregator() public view {
    (string memory aliasName, string memory zeroFeeAggregators) = loader.loadOperator(OPERATOR_EXAMPLE);
    assertEq(aliasName, "sepolia", "alias");
    assertEq(zeroFeeAggregators, "", "example names both fee aggregators");
  }

  function test_flagsZeroVerifierFeeAggregator() public {
    string memory zeroes = _loadWith("verifier-zero-fee-agg", VERIFIER_FEE_AGG);
    assertEq(zeroes, "verifiers[0x00010001].roles.feeAggregator", "verifier entry flagged by tag");
  }

  function test_flagsZeroResolverFeeAggregator() public {
    string memory zeroes = _loadWith("resolver-zero-fee-agg", RESOLVER_FEE_AGG);
    assertEq(zeroes, "resolver.roles.feeAggregator", "resolver entry flagged");
  }

  function test_flagsEveryZeroFeeAggregator() public view {
    Types.OperatorConfig memory operator;
    operator.verifiers = new Types.VerifierConfig[](2);
    operator.verifiers[0].versionTag = 0x00010001;
    operator.verifiers[0].roles.feeAggregator = address(0xFEE);
    operator.verifiers[1].versionTag = 0x00010002;
    assertEq(
      loader.zeroFeeAggregatorRoles(operator),
      "verifiers[0x00010002].roles.feeAggregator, resolver.roles.feeAggregator",
      "only the zero entries, in order"
    );
  }

  /// @dev Own fixture path per case: forge runs tests concurrently on a shared filesystem.
  function _loadWith(
    string memory caseName,
    string memory zeroedAddress
  ) private returns (string memory zeroFeeAggregators) {
    string memory path = string.concat("out/governance/operator-", caseName, ".local.json");
    vm.createDir("out/governance", true);
    vm.writeFile(path, vm.replace(vm.readFile(OPERATOR_EXAMPLE), zeroedAddress, ZERO));
    string memory aliasName;
    (aliasName, zeroFeeAggregators) = loader.loadOperator(path);
    assertEq(aliasName, "sepolia", "fixture still parses");
    vm.removeFile(path);
  }
}
