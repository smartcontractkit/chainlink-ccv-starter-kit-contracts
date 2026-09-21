// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {IOwnable} from "@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Concrete harness exposing BaseScript's internal dual-output API to tests.
///      Uses the explicit-mode initializer so tests never depend on process-global
///      env state (which is order- and parallelism-sensitive).
contract Harness is BaseScript {
  /// @dev Stands in for the executing Safe; only its presence in the batch JSON matters.
  address public constant SAFE = address(0x5AFE);

  /// @dev Scoped to "test" so the batch lands in out/safe/test/, apart from the batches a
  ///      real run produces.
  function initSafe() external {
    _initOutput(OutputMode.SAFE, "test", SAFE);
  }

  /// @dev Deliberately misconfigured (SAFE mode, no executing Safe) to exercise the
  ///      _flush backstop; real runs cannot reach this state, env-driven init refuses it.
  function initSafeWithoutAddress() external {
    _initOutput(OutputMode.SAFE, "test", address(0));
  }

  function initEoa() external {
    _initOutput(OutputMode.EOA, "", address(0));
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

  /// @dev Exposes the parser, not the env read: env state is process-global and forge
  ///      memoises vm.env*, so testing through OUTPUT_MODE itself would be order-sensitive.
  function parseMode(
    string calldata modeName
  ) external pure returns (OutputMode) {
    return _parseOutputMode(modeName);
  }

  function assertReachable(
    address target,
    string calldata label
  ) external view {
    _assertReachable(target, label);
  }
}

/// @dev Minimal Ownable2Step stand-in: the preflight only reads owner().
contract OwnedStub {
  address public owner;

  // a test stub; zero is as valid an owner fixture as any
  // forge-lint: disable-next-item(missing-zero-check)
  constructor(
    address owner_
  ) {
    owner = owner_;
  }
}

/// @notice Unit tests for the shared EOA/Safe output switch, the Safe Transaction
///         Builder JSON emitter, and the SAFE-mode executor preflights.
contract SafeOutputTest is Test {
  function test_safeMode_buffersAndEmitsValidBatch() public {
    Harness h = new Harness();
    h.initSafe();
    assertEq(uint256(h.mode()), uint256(BaseScript.OutputMode.SAFE));

    address target = address(0xABCD);
    h.stage(target, abi.encodeCall(IOwnable.acceptOwnership, ()));
    assertEq(h.count(), 1);

    h.flush("test-batch");
    // Buffer is cleared after flush.
    assertEq(h.count(), 0);

    string memory path = "out/safe/test/test-batch.json";
    string memory json = vm.readFile(path);

    assertEq(vm.parseJsonString(json, ".version"), "1.0");
    assertEq(vm.parseJsonString(json, ".chainId"), vm.toString(block.chainid));
    assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), h.SAFE(), "batch bound to the executing Safe");
    assertEq(vm.parseJsonAddress(json, ".transactions[0].to"), target);
    assertEq(vm.parseJsonString(json, ".transactions[0].value"), "0");
  }

  /// @dev A batch that names no executing Safe cannot be checked at import time, so
  ///      flushing without SAFE_ADDRESS is refused even via the explicit-mode seam.
  function test_flush_withoutSafeAddress_reverts() public {
    Harness h = new Harness();
    h.initSafeWithoutAddress();
    h.stage(address(0xABCD), abi.encodeWithSignature("acceptOwnership()"));

    vm.expectRevert(bytes("BaseScript: SAFE output needs SAFE_ADDRESS (the executing Safe)"));
    h.flush("unbound-batch");
  }

  /// @dev The backstop guards the batch write only: with nothing staged no file is
  ///      emitted, so an addressless flush stays a clean no-op.
  function test_flush_withoutSafeAddress_isNoOpWhenNothingStaged() public {
    Harness h = new Harness();
    h.initSafeWithoutAddress();

    string memory path = "out/safe/test/unbound-empty-batch.json";
    if (vm.exists(path)) vm.removeFile(path);

    h.flush("unbound-empty-batch");

    assertFalse(vm.exists(path), "no file written for an empty batch");
  }

  /// @dev An empty batch is not signable, so no file should appear at all.
  function test_flush_withNothingStaged_writesNoFile() public {
    Harness h = new Harness();
    h.initSafe();

    string memory path = "out/safe/test/empty-batch.json";
    if (vm.exists(path)) vm.removeFile(path);

    h.flush("empty-batch");

    assertFalse(vm.exists(path), "no file written for an empty batch");
  }

  /// @dev Before the empty-batch guard, an empty write overwrote the previous batch. With
  ///      the guard the write is skipped, so a stale file has to be removed explicitly or
  ///      a signer could import last run's calls as if they were current.
  function test_flush_withNothingStaged_removesAStaleBatch() public {
    Harness h = new Harness();
    h.initSafe();

    string memory path = "out/safe/test/stale-batch.json";
    h.stage(address(0xABCD), abi.encodeWithSignature("acceptOwnership()"));
    h.flush("stale-batch");
    assertTrue(vm.exists(path), "first run wrote a batch");

    // Second run stages nothing — e.g. every lane already matches on-chain.
    h.flush("stale-batch");

    assertFalse(vm.exists(path), "stale batch removed rather than left importable");
  }

  function test_parseOutputMode_acceptsTheTwoExactValues() public {
    Harness h = new Harness();
    assertEq(uint256(h.parseMode("EOA")), uint256(BaseScript.OutputMode.EOA));
    assertEq(uint256(h.parseMode("SAFE")), uint256(BaseScript.OutputMode.SAFE));
  }

  /// @dev OUTPUT_MODE fails closed: a missing value or any typo reverts rather than
  ///      defaulting to EOA, where --broadcast would execute live immediately.
  function test_parseOutputMode_rejectsMissingEmptyOrMistypedValues() public {
    Harness h = new Harness();
    string[5] memory bad = ["", "SAEF", "Safe", "safe", "eoa"];
    for (uint256 i = 0; i < bad.length; ++i) {
      vm.expectRevert(bytes(string.concat("BaseScript: OUTPUT_MODE must be exactly EOA or SAFE, got \"", bad[i], "\"")));
      // the expected revert is the assertion; the return never materialises
      // forge-lint: disable-next-line(unused-return)
      h.parseMode(bad[i]);
    }
  }

  function test_eoaMode_doesNotBuffer() public {
    Harness h = new Harness();
    h.initEoa();
    assertEq(uint256(h.mode()), uint256(BaseScript.OutputMode.EOA));
    // In EOA mode _stage would broadcast + call immediately; here we only assert the
    // buffer stays empty (no Safe batch is produced). See fork tests for broadcast paths.
    assertEq(h.count(), 0);
  }

  // ---------------------------------------------------------------------------
  //  SAFE-mode executor preflight — shared by every role-transfer script; the
  //  per-script wrappers are covered where their role getters live (Ownership.t.sol).
  // ---------------------------------------------------------------------------

  address internal constant INTERLOPER = address(0xBAD);
  address internal constant OWNER = address(0x0117);

  function test_executorPreflight_acceptsCurrentOwner() public {
    Harness h = new Harness();
    OwnedStub target = new OwnedStub(OWNER);
    h.requireExecutorIsCurrentOwner(address(target), OWNER);
  }

  function test_executorPreflight_rejectsNonOwner() public {
    Harness h = new Harness();
    OwnedStub target = new OwnedStub(OWNER);
    vm.expectRevert(
      bytes(
        string.concat(
          "BaseScript: SAFE_ADDRESS ",
          vm.toString(INTERLOPER),
          " is not the current owner of ",
          vm.toString(address(target)),
          "; the current owner is ",
          vm.toString(OWNER)
        )
      )
    );
    h.requireExecutorIsCurrentOwner(address(target), INTERLOPER);
  }

  function test_assertReachable_passesContract() public {
    Harness h = new Harness();
    h.assertReachable(address(h), "harness");
  }

  /// @dev Strict on zero: a caller that tolerates unrecorded targets guards before calling.
  function test_assertReachable_rejectsZeroAddress() public {
    Harness h = new Harness();
    vm.expectRevert(bytes("BaseScript: verifier is unset - not recorded in config?"));
    h.assertReachable(address(0), "verifier");
  }

  function test_assertReachable_rejectsCodelessAddress() public {
    Harness h = new Harness();
    address codeless = address(0xC0DE1E55);
    vm.expectRevert(
      bytes(
        string.concat("BaseScript: no code at verifier ", vm.toString(codeless), " - wrong --rpc-url, or none passed?")
      )
    );
    h.assertReachable(codeless, "verifier");
  }
}
