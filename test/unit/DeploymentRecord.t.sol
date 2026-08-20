// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Unit tests for the deployment-record read/write helpers used by the deploy
///         scripts to persist addresses into config/deployments/<alias>.json.
contract DeploymentRecordTest is Test {
  // Written under out/governance (gitignored *.local.json) to avoid polluting config/.
  string internal constant TMP_PATH = "out/governance/deploy-roundtrip.local.json";

  function test_writeRead_roundTrips() public {
    vm.createDir("out/governance", true);

    Types.Deployment memory d = Types.Deployment({
      aliasName: "testchain",
      factory: address(0x1111111111111111111111111111111111111111),
      resolver: address(0x2222222222222222222222222222222222222222),
      verifier: address(0x3333333333333333333333333333333333333333)
    });

    ConfigLib.writeDeploymentByPath(TMP_PATH, d);
    Types.Deployment memory got = ConfigLib.readDeploymentByPath(TMP_PATH);

    assertEq(got.aliasName, "testchain");
    assertEq(got.factory, d.factory);
    assertEq(got.resolver, d.resolver);
    assertEq(got.verifier, d.verifier);

    vm.removeFile(TMP_PATH);
  }

  function test_readDeploymentOrEmpty_missingReturnsAliasOnly() public view {
    Types.Deployment memory d = ConfigLib.readDeploymentOrEmpty("does-not-exist-xyz");
    assertEq(d.aliasName, "does-not-exist-xyz", "alias set");
    assertEq(d.factory, address(0), "no addresses");
    assertEq(d.resolver, address(0));
    assertEq(d.verifier, address(0));
  }
}
