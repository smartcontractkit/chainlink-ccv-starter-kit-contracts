// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CREATE2Factory} from "@chainlink/contracts-ccip/contracts/CREATE2Factory.sol";
import {console2} from "forge-std/console2.sol";

/// @title ApplyFactoryAllowlistUpdates
/// @notice Reconciles the CREATE2Factory's createAndCall allowlist with
///         `factory.allowlist` in config/roles/<alias>.json — the desired FULL set.
///         Stages only the delta (removes + adds) and skips when already matching,
///         so --rpc-url is required in BOTH output modes.
///         Caller must be the factory OWNER (applyAllowListUpdates is onlyOwner).
///
/// @dev The bootstrap deployer is constructor-allowlisted and nothing else removes it,
///      so it can claim CREATE2 addresses indefinitely. Prune it here once it is done.
///      Handover order: (1) BootstrapFactory, (2) resolver deployed and VERIFIED,
///      (3) configured factory owner has ACCEPTED ownership, (4) run this script.
///      To authorize a replacement deployment account later: add it to
///      `factory.allowlist`, run this, deploy, remove it, run this again.
///
/// @dev `factory.allowlist` is the desired FULL set. [] is valid intent: nobody may
///      createAndCall until the owner re-adds an account.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/ApplyFactoryAllowlistUpdates.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
///   (EOA path: OUTPUT_MODE=EOA + --broadcast --aws)
contract ApplyFactoryAllowlistUpdates is BaseScript {
  /// @notice Single source of truth for the applyAllowListUpdates calldata.
  function callsFor(
    address factory,
    address[] memory removes,
    address[] memory adds
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] =
      Call({to: factory, value: 0, data: abi.encodeCall(CREATE2Factory.applyAllowListUpdates, (removes, adds))});
  }

  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    // The diff below reads the factory, so an unrecorded or unreachable one must fail
    // here with a legible reason rather than as a bare revert inside getAllowList().
    _assertReachable(deployment.factory, "factory");

    // Zero entries are rejected inside readRoles (ConfigLib), so the desired set is clean here.
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);

    (address[] memory removes, address[] memory adds) = diff(deployment.factory, roles.factoryAllowlist);

    console2.log("[ApplyFactoryAllowlistUpdates] chain:", chainAlias);
    console2.log("  target factory:", deployment.factory);
    console2.log("  desired size:", roles.factoryAllowlist.length);
    console2.log("  on-chain size:", CREATE2Factory(deployment.factory).getAllowList().length);

    if (removes.length == 0 && adds.length == 0) {
      console2.log("[ApplyFactoryAllowlistUpdates] nothing to do: allowlist already matches config");
      _flush(string.concat("apply-factory-allowlist-updates-", chainAlias)); // removes any stale batch
      return;
    }

    // Delta logged before the guard below, so a guard revert still shows what was staged.
    for (uint256 i = 0; i < removes.length; ++i) {
      console2.log("  REMOVE:", removes[i]);
    }
    for (uint256 i = 0; i < adds.length; ++i) {
      console2.log("  ADD:   ", adds[i]);
    }
    if (roles.factoryAllowlist.length == 0) {
      console2.log("  NOTE: desired set is empty; nobody can createAndCall until the owner re-adds an account");
    }

    // Pruning before the CREATE2 deploys are done would block them; the resolver record
    // is the cheap proxy for "the bootstrap chain's deterministic deploys happened".
    if (removes.length > 0) {
      require(
        deployment.resolver != address(0),
        "ApplyFactoryAllowlistUpdates: resolver not recorded; finish CREATE2 deploys before pruning the allowlist"
      );
    }

    _stageMany(callsFor(deployment.factory, removes, adds));

    _flush(string.concat("apply-factory-allowlist-updates-", chainAlias));
  }

  /// @notice Delta between the desired full set and getAllowList(): what to remove and
  ///         what to add. Both empty when already current.
  function diff(
    address factory,
    address[] memory desired
  ) public view returns (address[] memory removes, address[] memory adds) {
    address[] memory current = CREATE2Factory(factory).getAllowList();
    removes = _difference(current, desired);
    adds = _difference(desired, current);
  }

  /// @dev Elements of `from` that are not in `exclude` (both treated as sets).
  function _difference(
    address[] memory from,
    address[] memory exclude
  ) private pure returns (address[] memory out) {
    address[] memory scratch = new address[](from.length);
    uint256 n = 0;
    for (uint256 i = 0; i < from.length; ++i) {
      if (!_contains(exclude, from[i])) scratch[n++] = from[i];
    }
    out = new address[](n);
    for (uint256 i = 0; i < n; ++i) {
      out[i] = scratch[i];
    }
  }

  function _contains(
    address[] memory haystack,
    address needle
  ) private pure returns (bool) {
    for (uint256 i = 0; i < haystack.length; ++i) {
      if (haystack[i] == needle) return true;
    }
    return false;
  }
}
