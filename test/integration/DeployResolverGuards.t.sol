// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeployResolver} from "../../script/deploy/DeployResolver.s.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Covers the config guards DeployResolver.run() applies before it deploys.
/// @dev Driven through run() rather than a helper, so the guard is covered at its call
///      site: a test that only exercised the condition would still pass if the line were
///      deleted from run().
contract DeployResolverGuardsTest is Test {
  /// @dev chainId 31337 matches the test EVM, resolverSalt is the template's all-zero
  ///      placeholder. The salt is checked before the roles and deployment reads, so no
  ///      roles fixture or deployment record is needed to reach it.
  string internal constant ALIAS_ZERO_SALT = "zz-scratch-zero-salt";

  DeployResolver internal script;

  function setUp() public {
    script = new DeployResolver();
  }

  function test_run_rejectsZeroResolverSalt() public {
    vm.expectRevert(
      bytes("DeployResolver: resolverSalt is zero (the _template.json placeholder); set a real salt in config/chains")
    );
    // called for its expected revert; the returned address is irrelevant
    // forge-lint: disable-next-line(unused-return)
    script.run(ALIAS_ZERO_SALT);
  }
}
