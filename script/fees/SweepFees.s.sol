// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @title SweepFees
/// @notice Sweeps accrued fee-token balances from BOTH the verifier
///         and the resolver to their (distinct) fee aggregators.
/// @dev Target call (both contracts, permissionless):
///        withdrawFeeTokens(address[] feeTokens)  -> transfers to that contract's feeAggregator.
/// @dev A zero feeAggregator makes the withdraw REVERT (FeeTokenHandler). This script
///      gates on the ON-CHAIN aggregator, not the intended value in config/roles: config
///      can be aspirational, only chain state decides whether the call reverts. Config is
///      still read, to warn on drift between the two.
/// @dev Gating reads chain state at build time, so --rpc-url is required even in SAFE
///      mode: without it every read sees a codeless address and nothing is staged.
/// @dev Because withdrawFeeTokens is permissionless it works from an EOA directly,
///      but is routed through _stage so a Safe batch can be produced too.
/// @dev The token list is NOT filtered by current balance. A Safe batch is built now and
///      executed later; filtering on today's balance would silently drop fees that accrue
///      in between. SKIP_ZERO_BALANCES=1 optionally skips a WHOLE contract whose every
///      configured token reads zero at build time (saves a no-op tx). Off by default:
///      balance-dependent batches regenerate differently as traffic accrues.
contract SweepFees is BaseScript {
  /// @notice Why a contract was not swept.
  enum SkipReason {
    None, // staged
    NoAggregator, // undeployed, or on-chain feeAggregator zero/unreadable: withdraw would revert
    NoBalance // no feeTokens configured, or every balance zero under SKIP_ZERO_BALANCES=1
  }

  /// @notice Calldata for one contract's sweep.
  function callsFor(
    address target,
    address[] memory feeTokens
  ) public pure returns (Call memory call) {
    return Call({to: target, value: 0, data: abi.encodeWithSignature("withdrawFeeTokens(address[])", feeTokens)});
  }

  /// @notice Reads the on-chain fee aggregator of both contracts.
  /// @dev Guarded on `code.length` before the call: a staticcall to a codeless address
  ///      succeeds with empty returndata and the ABI-decode failure is NOT catchable by
  ///      try/catch, so the guard - not the catch - is what makes this safe.
  function readAggregators(
    address verifier,
    address resolver
  ) public view returns (address verifierAggregator, address resolverAggregator) {
    if (verifier.code.length != 0) {
      try CommitteeVerifier(verifier).getDynamicConfig() returns (
        CommitteeVerifier.DynamicConfig memory dynamicConfig
      ) {
        verifierAggregator = dynamicConfig.feeAggregator;
      } catch {}
    }
    if (resolver.code.length != 0) {
      try VersionedVerifierResolver(resolver).getFeeAggregator() returns (address agg) {
        resolverAggregator = agg;
      } catch {}
    }
  }

  /// @notice Decides which contracts are safe and worth sweeping, and builds their calls.
  /// @param skipZeroBalances Also skip a contract whose every configured token reads zero
  ///        right now. Optional: a no-op sweep is harmless, just gas.
  /// @return calls Sweep calls, in verifier-then-resolver order. Empty when nothing is sweepable.
  /// @return verifierSkip Why the verifier was skipped (None when staged).
  /// @return resolverSkip Why the resolver was skipped (None when staged).
  function sweepCalls(
    Types.Deployment memory deployment,
    Types.ChainConfig memory chainConfig,
    bool skipZeroBalances
  ) public view returns (Call[] memory calls, SkipReason verifierSkip, SkipReason resolverSkip) {
    // No fee tokens configured => nothing to sweep anywhere.
    if (chainConfig.feeTokens.length == 0) {
      return (new Call[](0), SkipReason.NoBalance, SkipReason.NoBalance);
    }

    (address vAgg, address rAgg) = readAggregators(deployment.verifier, deployment.resolver);

    verifierSkip = _skipReason(deployment.verifier, vAgg, chainConfig.feeTokens, skipZeroBalances);
    resolverSkip = _skipReason(deployment.resolver, rAgg, chainConfig.feeTokens, skipZeroBalances);

    uint256 sweepableCount = (verifierSkip == SkipReason.None ? 1 : 0) + (resolverSkip == SkipReason.None ? 1 : 0);
    calls = new Call[](sweepableCount);
    uint256 i;
    if (verifierSkip == SkipReason.None) calls[i++] = callsFor(deployment.verifier, chainConfig.feeTokens);
    if (resolverSkip == SkipReason.None) calls[i++] = callsFor(deployment.resolver, chainConfig.feeTokens);
  }

  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    Types.ChainConfig memory chainConfig = ConfigLib.readChain(chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);
    bool skipZeroBalances = vm.envOr("SKIP_ZERO_BALANCES", false);

    console2.log("[SweepFees] chain:", chainAlias);
    console2.log("  fee tokens configured:", chainConfig.feeTokens.length);

    if (chainConfig.feeTokens.length == 0) {
      console2.log("  no feeTokens in config/chains/<alias>.json; nothing to sweep (no-op)");
      return;
    }

    _assertReachable(deployment.verifier, "verifier");
    _assertReachable(deployment.resolver, "resolver");

    (address vAgg, address rAgg) = readAggregators(deployment.verifier, deployment.resolver);

    // Warn on drift between chain state and the intended holder in config/roles.
    if (roles.verifier.feeAggregator != address(0) && vAgg != roles.verifier.feeAggregator) {
      console2.log("  DRIFT verifier feeAggregator on-chain:", vAgg);
      console2.log("        config/roles expects:", roles.verifier.feeAggregator);
    }
    if (roles.resolver.feeAggregator != address(0) && rAgg != roles.resolver.feeAggregator) {
      console2.log("  DRIFT resolver feeAggregator on-chain:", rAgg);
      console2.log("        config/roles expects:", roles.resolver.feeAggregator);
    }

    (Call[] memory calls, SkipReason verifierSkip, SkipReason resolverSkip) =
      sweepCalls(deployment, chainConfig, skipZeroBalances);

    _logOutcome("verifier", verifierSkip, vAgg);
    _logOutcome("resolver", resolverSkip, rAgg);

    if (calls.length == 0) {
      console2.log("  nothing sweepable; no batch written");
      return;
    }

    _stageMany(calls);
    _flush("sweep-fees");
  }

  /// @dev True when the contract holds a non-zero balance in ANY configured token.
  ///      Codeless or non-ERC20 entries count as zero rather than aborting the read.
  function _hasAnyBalance(
    address target,
    address[] memory feeTokens
  ) private view returns (bool) {
    for (uint256 i; i < feeTokens.length; ++i) {
      if (feeTokens[i].code.length == 0) continue;
      try IERC20(feeTokens[i]).balanceOf(target) returns (uint256 bal) {
        if (bal > 0) return true;
      } catch {}
    }
    return false;
  }

  function _skipReason(
    address target,
    address aggregator,
    address[] memory feeTokens,
    bool skipZeroBalances
  ) private view returns (SkipReason) {
    if (target == address(0) || aggregator == address(0)) return SkipReason.NoAggregator;
    if (skipZeroBalances && !_hasAnyBalance(target, feeTokens)) return SkipReason.NoBalance;
    return SkipReason.None;
  }

  function _logOutcome(
    string memory label,
    SkipReason reason,
    address aggregator
  ) private pure {
    if (reason == SkipReason.NoAggregator) {
      console2.log(
        string.concat("  SKIP ", label, ": undeployed or on-chain feeAggregator zero (withdraw would revert)")
      );
    } else if (reason == SkipReason.NoBalance) {
      console2.log(string.concat("  SKIP ", label, ": no fee-token balance (SKIP_ZERO_BALANCES=1)"));
    } else {
      console2.log(string.concat("  sweeping ", label, " -> aggregator:"), aggregator);
    }
  }

  /// @dev A recorded address with no code means the wrong RPC (or none), not an empty
  ///      balance. Without this the reads below silently yield zero and the sweep looks
  ///      like a clean no-op. Unrecorded (zero) targets are a real state, so they pass.
  function _assertReachable(
    address target,
    string memory label
  ) private view {
    if (target == address(0)) return;
    require(
      target.code.length != 0,
      string.concat(
        "SweepFees: no code at recorded ", label, " ", vm.toString(target), " - wrong --rpc-url, or none passed?"
      )
    );
  }
}
