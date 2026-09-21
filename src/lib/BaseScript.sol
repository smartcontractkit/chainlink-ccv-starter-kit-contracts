// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "./ConfigLib.sol";
import {Ownable2Step} from "@chainlink/contracts/src/v0.8/shared/access/Ownable2Step.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title BaseScript
/// @notice Shared base for every config / role-transfer script. Centralises the
///         dual-output concern so no script duplicates it:
///
///           * EOA: each staged call is broadcast immediately.
///           * SAFE: staged calls are buffered and flushed to a Safe
///             Transaction Builder JSON batch under `out/safe/`, key-free
///             (addresses + calldata only), ready for signers to import.
///
///         Select the mode with the `OUTPUT_MODE` env var: exactly `EOA` or `SAFE`,
///         no default — EOA means live broadcasts, so it must be an explicit opt-in.
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
  /// @dev Chain alias this run targets; becomes the out/safe/ subdirectory.
  string internal outputChainAlias;
  /// @dev The Safe expected to execute the batch; embedded in the batch JSON so the
  ///      Transaction Builder flags an import into a different Safe.
  address internal outputSafeAddress;
  Call[] private _staged;

  /// @notice Call once at the top of `run()`. Verifies the chain config against the
  ///         connected network (ConfigLib.assertChain), then reads OUTPUT_MODE and
  ///         reverts on a missing, empty, or unknown value, no default. SAFE mode also
  ///         requires SAFE_ADDRESS (the executing Safe); EOA mode ignores it with a log.
  /// @param chainAlias The chain this run targets. A Safe batch executes on ONE chain, so
  ///        this scopes the output directory; without it two chains overwrite each other.
  function _initOutput(
    string memory chainAlias
  ) internal {
    ConfigLib.assertChain(chainAlias);
    OutputMode mode = _parseOutputMode(vm.envOr("OUTPUT_MODE", string("")));
    // Read as a string first: a malformed value must not abort an EOA run that ignores it.
    string memory safeRaw = vm.envOr("SAFE_ADDRESS", string(""));
    address safeAddress = address(0);
    if (mode == OutputMode.SAFE) {
      require(bytes(safeRaw).length != 0, "BaseScript: SAFE output needs SAFE_ADDRESS (the executing Safe)");
      safeAddress = vm.parseAddress(safeRaw);
      require(safeAddress != address(0), "BaseScript: SAFE_ADDRESS must not be the zero address");
    } else if (bytes(safeRaw).length != 0) {
      console2.log("[BaseScript] EOA mode: SAFE_ADDRESS is set but ignored");
    }
    _initOutput(mode, chainAlias, safeAddress);
  }

  /// @dev Case-sensitive exact match on purpose: this decides whether calls go on-chain
  ///      immediately, so anything else fails closed instead of guessing.
  function _parseOutputMode(
    string memory modeName
  ) internal pure returns (OutputMode) {
    if (_stringsEqual(modeName, "EOA")) return OutputMode.EOA;
    if (_stringsEqual(modeName, "SAFE")) return OutputMode.SAFE;
    revert(string.concat("BaseScript: OUTPUT_MODE must be exactly EOA or SAFE, got \"", modeName, "\""));
  }

  /// @notice Explicit-mode variant that bypasses env vars. Prefer this in tests
  ///         (env-driven selection mutates process-global state and is order- and
  ///         parallelism-sensitive) and in callers that already know the mode.
  ///         EOA mode has no executing Safe; pass address(0).
  function _initOutput(
    OutputMode mode,
    string memory chainAlias,
    address safeAddress
  ) internal {
    outputMode = mode;
    outputChainAlias = chainAlias;
    outputSafeAddress = safeAddress;
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
      // a generic executor: the destination is caller-supplied by design
      // forge-lint: disable-next-line(arbitrary-send-eth)
      (bool ok, bytes memory returnData) = to.call{value: value}(data);
      if (!ok) _bubbleRevert(returnData);
    } else {
      _staged.push(Call({to: to, value: value, data: data}));
    }
  }

  /// @notice Stage a pre-built Call (as returned by the per-operation `callsFor`
  ///         builders on the individual scripts).
  function _stage(
    Call memory call
  ) internal {
    _stage(call.to, call.value, call.data);
  }

  /// @notice Stage a batch of pre-built Calls, preserving order.
  function _stageMany(
    Call[] memory calls
  ) internal {
    for (uint256 i = 0; i < calls.length; ++i) {
      _stage(calls[i]);
    }
  }

  /// @notice In SAFE mode, write the buffered calls to a Safe Transaction Builder
  ///         batch. One file per batch: the Builder imports one at a time.
  ///         No-op in EOA mode, and no file at all when nothing was staged.
  function _flush(
    string memory name
  ) internal {
    if (outputMode != OutputMode.SAFE) return;
    // Directory name comes from the supplied chain alias, not block.chainid.
    require(bytes(outputChainAlias).length != 0, "BaseScript: SAFE output needs a chain alias");
    string memory dir = string.concat("out/safe/", outputChainAlias);
    string memory file = string.concat(dir, "/", _fileSafe(name), ".json");
    // An empty batch is not signable, and writing one leaves an artifact that reads as
    // output. Any batch already at this path is from an earlier run and no longer
    // reflects config, so remove it rather than leave it to be imported as if fresh.
    if (_staged.length == 0) {
      console2.log("[BaseScript] nothing staged; no Safe batch written:", file);
      if (vm.exists(file)) {
        vm.removeFile(file);
        console2.log("[BaseScript]   removed a stale batch from an earlier run");
      }
      return;
    }
    // Backstop for explicit-mode callers: every batch written must name its executing
    // Safe for the Transaction Builder's import check.
    require(outputSafeAddress != address(0), "BaseScript: SAFE output needs SAFE_ADDRESS (the executing Safe)");

    // Snapshot, then clear _staged before the file-system calls (checks-effects order).
    string memory json = _buildSafeJson(name);
    uint256 stagedTotal = _staged.length;
    delete _staged;

    vm.createDir(dir, true); // idempotent; survives a fresh clone
    vm.writeFile(file, json);
    console2.log("[BaseScript] Safe batch written:", file);
    console2.log("[BaseScript]   transactions:", stagedTotal);
  }

  /// @dev Batch names can embed a target like "verifier:0x00010001", and ':' is not a
  ///      portable filename character — it becomes '-'.
  function _fileSafe(
    string memory name
  ) private pure returns (string memory) {
    bytes memory raw = bytes(name);
    for (uint256 i = 0; i < raw.length; ++i) {
      if (raw[i] == bytes1(0x3A)) raw[i] = bytes1(0x2D); // ':' -> '-'
    }
    return string(raw);
  }

  function stagedCount() internal view returns (uint256) {
    return _staged.length;
  }

  // ---------------------------------------------------------------------------
  //  SAFE-mode executor preflight
  //
  //  The staged calls are role-gated on-chain, so a batch from any other Safe is
  //  dead on arrival: fail at build time, before signatures are collected. EOA runs
  //  need none of this — forge's pre-broadcast simulation already reverts there.
  // ---------------------------------------------------------------------------

  /// @notice Reverts unless expectedExecutor is the target's current owner.
  function requireExecutorIsCurrentOwner(
    address target,
    address expectedExecutor
  ) public view {
    _requireExecutorHoldsRole(target, expectedExecutor, Ownable2Step(target).owner(), "current owner");
  }

  /// @dev Role-agnostic core: the caller reads the holder, so roles BaseScript has no
  ///      business importing (e.g. CommitteeVerifier's admin) reuse the same assertion.
  function _requireExecutorHoldsRole(
    address target,
    address expectedExecutor,
    address currentHolder,
    string memory rolePhrase
  ) internal pure {
    require(
      expectedExecutor == currentHolder,
      string.concat(
        "BaseScript: SAFE_ADDRESS ",
        vm.toString(expectedExecutor),
        " is not the ",
        rolePhrase,
        " of ",
        vm.toString(target),
        "; the ",
        rolePhrase,
        " is ",
        vm.toString(currentHolder)
      )
    );
  }

  /// @dev Preflights read chain state; against a codeless address the getter would fail
  ///      undecodably instead of pointing at the real problem. Zero is refused too, with
  ///      a config-shaped message: a caller that tolerates unrecorded targets guards first.
  function _assertReachable(
    address target,
    string memory label
  ) internal view {
    require(target != address(0), string.concat("BaseScript: ", label, " is unset - not recorded in config?"));
    require(
      target.code.length != 0,
      string.concat("BaseScript: no code at ", label, " ", vm.toString(target), " - wrong --rpc-url, or none passed?")
    );
  }

  // ---------------------------------------------------------------------------
  //  Safe Transaction Builder JSON (v1.0 schema)
  // ---------------------------------------------------------------------------
  function _buildSafeJson(
    string memory name
  ) private view returns (string memory) {
    string memory txs = "";
    for (uint256 i = 0; i < _staged.length; ++i) {
      Call memory stagedCall = _staged[i];
      string memory one = string.concat(
        '{"to":"',
        vm.toString(stagedCall.to),
        '","value":"',
        vm.toString(stagedCall.value),
        '","data":"',
        vm.toString(stagedCall.data),
        '","contractMethod":null,"contractInputsValues":null}'
      );
      txs = i == 0 ? one : string.concat(txs, ",", one);
    }

    string memory meta = string.concat(
      '"meta":{"name":"', name, '","description":"CCV Starter Kit generated batch","txBuilderVersion":"1.16.5"'
    );
    // The Transaction Builder compares this against the Safe importing the batch and
    // flags a mismatch, so a batch built for the wrong Safe is caught before signing.
    meta = string.concat(meta, ',"createdFromSafeAddress":"', vm.toString(outputSafeAddress), '"}');
    return string.concat(
      '{"version":"1.0","chainId":"', vm.toString(_outputChainId()), '",', meta, ',"transactions":[', txs, "]}"
    );
  }

  /// @dev Safe validates chainId on import. The id comes from the chain config — the
  ///      declared intent, already verified against the connection by assertChain —
  ///      falling back to `block.chainid` only for a scope with no chain file (e.g. tests).
  function _outputChainId() private view returns (uint256 chainId) {
    chainId = ConfigLib.readChainOrEmpty(outputChainAlias).chainId;
    if (chainId == 0) chainId = block.chainid;
  }

  // ---------------------------------------------------------------------------
  //  helpers
  // ---------------------------------------------------------------------------
  function _stringsEqual(
    string memory left,
    string memory right
  ) internal pure returns (bool) {
    return keccak256(bytes(left)) == keccak256(bytes(right));
  }

  function _bubbleRevert(
    bytes memory returnData
  ) private pure {
    if (returnData.length > 0) {
      // solhint-disable-next-line no-inline-assembly
      assembly {
        revert(add(returnData, 0x20), mload(returnData))
      }
    }
    revert("BaseScript: staged call reverted");
  }
}
