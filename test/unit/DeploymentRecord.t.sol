// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Unit tests for the deployment-record read/write helpers used by the deploy
///         scripts to persist addresses into config/deployments/<alias>.json.
contract DeploymentRecordTest is Test {
  // Written under out/governance (gitignored *.local.json) to avoid polluting config/.
  // Forge runs tests concurrently against a shared filesystem, so each test writing a
  // fixture file must use its OWN path.
  string internal constant TMP_PATH = "out/governance/deploy-roundtrip.local.json";

  function test_writeRead_roundTrips() public {
    vm.createDir("out/governance", true);

    Types.Deployment memory d;
    d.aliasName = "testchain";
    d.factory = address(0x1111111111111111111111111111111111111111);
    d.resolver = address(0x2222222222222222222222222222222222222222);
    d.verifiers = new Types.VerifierDeployment[](2);
    d.verifiers[0] =
      Types.VerifierDeployment({versionTag: 0x00010001, addr: address(0x3333333333333333333333333333333333333333)});
    d.verifiers[1] =
      Types.VerifierDeployment({versionTag: 0x00010002, addr: address(0x4444444444444444444444444444444444444444)});

    ConfigLib.writeDeploymentByPath(TMP_PATH, d);
    Types.Deployment memory got = ConfigLib.readDeploymentByPath(TMP_PATH);

    assertEq(got.aliasName, "testchain");
    assertEq(got.factory, d.factory);
    assertEq(got.resolver, d.resolver);
    assertEq(got.verifiers.length, 2, "both verifiers survive the round trip");
    assertEq(got.verifiers[0].versionTag, d.verifiers[0].versionTag);
    assertEq(got.verifiers[0].addr, d.verifiers[0].addr);
    assertEq(got.verifiers[1].versionTag, d.verifiers[1].versionTag);
    assertEq(got.verifiers[1].addr, d.verifiers[1].addr);

    vm.removeFile(TMP_PATH);
  }

  function test_writeRead_roundTripsEmptyVerifiers() public {
    string memory path = "out/governance/deploy-roundtrip-empty.local.json";
    vm.createDir("out/governance", true);

    Types.Deployment memory d;
    d.aliasName = "testchain";
    d.factory = address(0x1111111111111111111111111111111111111111);

    ConfigLib.writeDeploymentByPath(path, d);
    Types.Deployment memory got = ConfigLib.readDeploymentByPath(path);
    assertEq(got.verifiers.length, 0, "no verifiers recorded yet");

    vm.removeFile(path);
  }

  function test_readDeploymentOrEmpty_missingReturnsAliasOnly() public view {
    Types.Deployment memory d = ConfigLib.readDeploymentOrEmpty("does-not-exist-xyz");
    assertEq(d.aliasName, "does-not-exist-xyz", "alias set");
    assertEq(d.factory, address(0), "no addresses");
    assertEq(d.resolver, address(0));
    assertEq(d.verifiers.length, 0);
  }

  function test_read_revertsOnDuplicateTag() public {
    string memory json = string.concat(
      '{"alias":"dup","factory":"0x1111111111111111111111111111111111111111",',
      '"resolver":"0x2222222222222222222222222222222222222222","verifiers":[',
      '{"versionTag":"0x00010001","address":"0x3333333333333333333333333333333333333333"},',
      '{"versionTag":"0x00010001","address":"0x4444444444444444444444444444444444444444"}]}'
    );
    _expectReadRevert("dup", json, "duplicate versionTag");
  }

  function test_read_revertsOnZeroTag() public {
    string memory json = string.concat(
      '{"alias":"zt","factory":"0x1111111111111111111111111111111111111111",',
      '"resolver":"0x2222222222222222222222222222222222222222","verifiers":[',
      '{"versionTag":"0x00000000","address":"0x3333333333333333333333333333333333333333"}]}'
    );
    _expectReadRevert("zero-tag", json, "is malformed");
  }

  function test_read_revertsOnZeroAddress() public {
    string memory json = string.concat(
      '{"alias":"za","factory":"0x1111111111111111111111111111111111111111",',
      '"resolver":"0x2222222222222222222222222222222222222222","verifiers":[',
      '{"versionTag":"0x00010001","address":"0x0000000000000000000000000000000000000000"}]}'
    );
    _expectReadRevert("zero-addr", json, "zero verifier address");
  }

  function _expectReadRevert(
    string memory caseName,
    string memory json,
    string memory reasonFragment
  ) private {
    string memory path = string.concat("out/governance/deploy-", caseName, ".local.json");
    vm.createDir("out/governance", true);
    vm.writeFile(path, json);
    try this.callRead(path) {
      fail();
    } catch Error(string memory reason) {
      assertTrue(vm.contains(reason, reasonFragment), string.concat("reason names the problem: ", reason));
    }
    vm.removeFile(path);
  }

  /// @dev External wrapper: library internals inline, and the revert must happen in a CALL.
  function callRead(
    string calldata path
  ) external view returns (Types.Deployment memory) {
    return ConfigLib.readDeploymentByPath(path);
  }
}
