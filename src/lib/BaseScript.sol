// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title BaseScript
/// @notice Shared base for every config / role-transfer script. Centralises the
///         dual-output concern so no script duplicates it:
///
///           * Phase 1 (EOA): each staged call is broadcast immediately.
///           * Phase 2 (SAFE): staged calls are buffered and flushed to a Safe
///             Transaction Builder JSON batch under `out/safe/`, key-free
///             (addresses + calldata only), ready for signers to import.
///
///         Select the mode with the `OUTPUT_MODE` env var (`EOA` | `SAFE`).
///
/// @dev Deploy scripts (BootstrapFactory / DeployResolver / DeployVerifier) do
///      NOT use `_stage`: the factory bootstrap is intrinsically EOA-only
///      (fresh deployer at nonce 0) and the initial deploys broadcast directly.
///      The dual-output path is for CONFIGURATION and ROLE-TRANSFER scripts.
abstract contract BaseScript is Script {
  enum OutputMode {
    EOA,
    SAFE
  }

  struct Call {
    address to;
    uint256 value;
    bytes data;
  }

  OutputMode internal outputMode;
  string internal safeAddress; // optional: the executing Safe, recorded in batch meta
  Call[] private _staged;

  /// @notice Call once at the top of `run()`. Reads OUTPUT_MODE / SAFE_ADDRESS.
  function _initOutput() internal {
    string memory m = vm.envOr("OUTPUT_MODE", string("EOA"));
    OutputMode mode = (_eq(m, "SAFE") || _eq(m, "safe")) ? OutputMode.SAFE : OutputMode.EOA;
    _initOutput(mode, vm.envOr("SAFE_ADDRESS", string("")));
  }

  /// @notice Explicit-mode variant that bypasses env vars. Prefer this in tests
  ///         (env-driven selection mutates process-global state and is order- and
  ///         parallelism-sensitive) and in callers that already know the mode.
  function _initOutput(
    OutputMode mode,
    string memory safe
  ) internal {
    outputMode = mode;
    safeAddress = safe;
    delete _staged;
    console2.log("[BaseScript] output mode:", outputMode == OutputMode.SAFE ? "SAFE" : "EOA");
  }

  /// @notice Stage a privileged call (value 0). EOA => broadcast now; SAFE => buffer.
  function _stage(
    address to,
    bytes memory data
  ) internal {
    _stage(to, 0, data);
  }

  function _stage(
    address to,
    uint256 value,
    bytes memory data
  ) internal {
    if (outputMode == OutputMode.EOA) {
      vm.broadcast();
      (bool ok, bytes memory ret) = to.call{value: value}(data);
      if (!ok) _bubbleRevert(ret);
    } else {
      _staged.push(Call({to: to, value: value, data: data}));
    }
  }

  /// @notice Stage a pre-built Call (as returned by the per-operation `callsFor`
  ///         builders on the individual scripts).
  function _stage(
    Call memory c
  ) internal {
    _stage(c.to, c.value, c.data);
  }

  /// @notice Stage a batch of pre-built Calls, preserving order.
  function _stageMany(
    Call[] memory calls
  ) internal {
    for (uint256 i; i < calls.length; ++i) {
      _stage(calls[i]);
    }
  }

  /// @notice In SAFE mode, write the buffered calls to a Safe Transaction Builder
  ///         batch. `name` should carry the execution order prefix so signers
  ///         cannot reorder multi-step ceremonies, e.g. "a-transfer-owner".
  ///         No-op in EOA mode.
  function _flush(
    string memory name
  ) internal {
    if (outputMode != OutputMode.SAFE) return;
    vm.createDir("out/safe", true); // idempotent; survives a fresh clone
    string memory file = string.concat("out/safe/", name, "-", vm.toString(block.chainid), ".json");
    vm.writeFile(file, _buildSafeJson(name));
    console2.log("[BaseScript] Safe batch written:", file);
    console2.log("[BaseScript]   transactions:", _staged.length);
    delete _staged;
  }

  function stagedCount() internal view returns (uint256) {
    return _staged.length;
  }

  // ---------------------------------------------------------------------------
  //  Safe Transaction Builder JSON (v1.0 schema)
  // ---------------------------------------------------------------------------
  function _buildSafeJson(
    string memory name
  ) private view returns (string memory) {
    string memory txs = "";
    for (uint256 i; i < _staged.length; ++i) {
      Call memory c = _staged[i];
      string memory one = string.concat(
        '{"to":"',
        vm.toString(c.to),
        '","value":"',
        vm.toString(c.value),
        '","data":"',
        vm.toString(c.data),
        '","contractMethod":null,"contractInputsValues":null}'
      );
      txs = i == 0 ? one : string.concat(txs, ",", one);
    }

    string memory meta = string.concat(
      '"meta":{"name":"', name, '","description":"CCV Starter Kit generated batch","txBuilderVersion":"1.16.5"'
    );
    if (bytes(safeAddress).length > 0) {
      meta = string.concat(meta, ',"createdFromSafeAddress":"', safeAddress, '"');
    }
    meta = string.concat(meta, "}");

    return string.concat(
      '{"version":"1.0","chainId":"', vm.toString(block.chainid), '",', meta, ',"transactions":[', txs, "]}"
    );
  }

  // ---------------------------------------------------------------------------
  //  helpers
  // ---------------------------------------------------------------------------
  function _eq(
    string memory a,
    string memory b
  ) internal pure returns (bool) {
    return keccak256(bytes(a)) == keccak256(bytes(b));
  }

  function _bubbleRevert(
    bytes memory ret
  ) private pure {
    if (ret.length > 0) {
      // solhint-disable-next-line no-inline-assembly
      assembly {
        revert(add(ret, 0x20), mload(ret))
      }
    }
    revert("BaseScript: staged call reverted");
  }
}
