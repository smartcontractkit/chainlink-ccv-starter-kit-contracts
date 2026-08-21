// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Concrete harness exposing BaseScript's internal dual-output API to tests.
///      Uses the explicit-mode initializer so tests never depend on process-global
///      env state (which is order- and parallelism-sensitive).
contract Harness is BaseScript {
  /// @dev Scoped to "test" so the batch lands in out/safe/test/, which .gitignore
  ///      excludes as a directory. Everything else under out/safe/ is committed.
  function initSafe(
    string calldata safe
  ) external {
    _initOutput(OutputMode.SAFE, safe, "test");
  }

  function initEoa() external {
    _initOutput(OutputMode.EOA, "");
  }

  function mode() external view returns (OutputMode) {
    return outputMode;
  }

  function stage(
    address to,
    bytes calldata data
  ) external {
    _stage(to, data);
  }

  function flush(
    string calldata name
  ) external {
    _flush(name);
  }

  function count() external view returns (uint256) {
    return stagedCount();
  }
}

/// @notice Unit tests for the shared EOA/Safe output switch and Safe Transaction
///         Builder JSON emitter.
contract SafeOutputTest is Test {
  function test_safeMode_buffersAndEmitsValidBatch() public {
    Harness h = new Harness();
    h.initSafe("0x00000000000000000000000000000000000000A5");
    assertEq(uint256(h.mode()), uint256(BaseScript.OutputMode.SAFE));

    address target = address(0xABCD);
    h.stage(target, abi.encodeWithSignature("acceptOwnership()"));
    assertEq(h.count(), 1);

    h.flush("test-batch");
    // Buffer is cleared after flush.
    assertEq(h.count(), 0);

    string memory path = "out/safe/test/test-batch.json";
    string memory json = vm.readFile(path);

    assertEq(vm.parseJsonString(json, ".version"), "1.0");
    assertEq(vm.parseJsonString(json, ".chainId"), vm.toString(block.chainid));
    assertEq(vm.parseJsonAddress(json, ".transactions[0].to"), target);
    assertEq(vm.parseJsonString(json, ".transactions[0].value"), "0");
  }

  function test_eoaMode_doesNotBuffer() public {
    Harness h = new Harness();
    h.initEoa();
    assertEq(uint256(h.mode()), uint256(BaseScript.OutputMode.EOA));
    // In EOA mode _stage would broadcast + call immediately; here we only assert the
    // buffer stays empty (no Safe batch is produced). See fork tests for broadcast paths.
    assertEq(h.count(), 0);
  }
}
