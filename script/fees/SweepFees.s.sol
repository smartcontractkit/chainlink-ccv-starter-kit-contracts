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
/// @notice Sweeps accrued fee-token balances from the verifier and the resolver to
///         their (distinct) fee aggregators via the permissionless withdrawFeeTokens.
/// @dev Both contracts must be deployed; beyond that each is gated independently -
///      skipped while neither chain nor config/roles names its aggregator, reverted
///      when the two disagree in any way.
///      Reads chain state at build time, so --rpc-url is required even in SAFE mode.
/// @dev Zero-balance tokens are omitted by default; SKIP_ZERO_BALANCES=false stages
///      every configured token, for batches executed long after they are built.
contract SweepFees is BaseScript {
  function run(
    string calldata chainAlias
  ) external {
    _initOutput(chainAlias);
    bool skipZeroBalances = vm.envOr("SKIP_ZERO_BALANCES", true);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    Types.ChainConfig memory chainConfig = ConfigLib.readChain(chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);

    console2.log("[SweepFees] chain:", chainAlias);
    if (chainConfig.feeTokens.length == 0) {
      console2.log(string.concat("  no feeTokens in config/chains/", chainAlias, ".json; nothing to sweep (no-op)"));
      return;
    }
    console2.log("  fee tokens configured:", chainConfig.feeTokens.length);

    // Both contracts must be deployed and reachable; a partial deployment is an error.
    require(deployment.verifier != address(0), "SweepFees: no verifier recorded in config/deployments");
    require(deployment.resolver != address(0), "SweepFees: no resolver recorded in config/deployments");
    _assertReachable(deployment.verifier, "verifier");
    _assertReachable(deployment.resolver, "resolver");

    Call[] memory calls = buildSweepBatch(deployment, roles, chainConfig.feeTokens, skipZeroBalances);

    if (calls.length == 0) {
      console2.log("  nothing sweepable; no batch written");
      return;
    }
    _stageMany(calls);
    _flush("sweep-fees");
  }

  /// @notice Builds the sweep batch for both contracts from config and chain state.
  ///         Each contract is gated independently, so one being skipped - not in use,
  ///         nothing held - never blocks the other. Reverts on misconfiguration: a
  ///         broken token entry, or an aggregator named on only one side of
  ///         chain/config or named differently on each.
  function buildSweepBatch(
    Types.Deployment memory deployment,
    Types.RolesConfig memory roles,
    address[] memory feeTokens,
    bool skipZeroBalances
  ) public view returns (Call[] memory calls) {
    (address verifierAggregator, address resolverAggregator) = readAggregators(deployment.verifier, deployment.resolver);

    // An empty token list is the natural "nothing to stage" signal for a contract.
    address[] memory verifierTokens = new address[](0);
    address[] memory resolverTokens = new address[](0);

    _requireAggregatorMatchesConfig("verifier", verifierAggregator, roles.verifier.feeAggregator);
    _requireAggregatorMatchesConfig("resolver", resolverAggregator, roles.resolver.feeAggregator);

    if (verifierAggregator == address(0)) {
      console2.log("  SKIP verifier: not in use (no feeAggregator on-chain or in config/roles)");
    } else {
      verifierTokens = sweepableTokens(deployment.verifier, feeTokens, skipZeroBalances);
      if (verifierTokens.length == 0) console2.log("  SKIP verifier: no fee-token balance");
    }
    if (resolverAggregator == address(0)) {
      console2.log("  SKIP resolver: not in use (no feeAggregator on-chain or in config/roles)");
    } else {
      resolverTokens = sweepableTokens(deployment.resolver, feeTokens, skipZeroBalances);
      if (resolverTokens.length == 0) console2.log("  SKIP resolver: no fee-token balance");
    }

    calls = new Call[]((verifierTokens.length != 0 ? 1 : 0) + (resolverTokens.length != 0 ? 1 : 0));
    uint256 n = 0;
    if (verifierTokens.length != 0) calls[n++] = buildWithdrawCall(deployment.verifier, verifierTokens);
    if (resolverTokens.length != 0) calls[n++] = buildWithdrawCall(deployment.resolver, resolverTokens);
  }

  /// @dev Chain and config/roles must agree on the aggregator. Matching zeros mean the
  ///      contract is not in use yet (a legitimate skip); any other disagreement is drift.
  function _requireAggregatorMatchesConfig(
    string memory label,
    address onchainAggregator,
    address intendedAggregator
  ) private pure {
    if (onchainAggregator == intendedAggregator) return;
    require(
      intendedAggregator != address(0),
      string.concat("SweepFees: ", label, " feeAggregator is not declared in config/roles - declare it before sweeping")
    );
    revert(
      string.concat(
        "SweepFees: ",
        label,
        " feeAggregator on-chain ",
        vm.toString(onchainAggregator),
        " does not match config/roles ",
        vm.toString(intendedAggregator)
      )
    );
  }

  /// @notice The withdraw calldata for one contract's sweep.
  /// @dev CommitteeVerifier and VersionedVerifierResolver declare the identical
  ///      withdrawFeeTokens(address[]), so one encoding serves both targets.
  function buildWithdrawCall(
    address target,
    address[] memory feeTokens
  ) public pure returns (Call memory call) {
    return Call({to: target, value: 0, data: abi.encodeCall(CommitteeVerifier.withdrawFeeTokens, (feeTokens))});
  }

  /// @notice Reads the on-chain fee aggregator of both contracts.
  /// @dev Guarded on `code.length` before the call: a staticcall to a codeless address
  ///      succeeds with empty returndata and the ABI-decode failure is NOT catchable by
  ///      try/catch, so the guard - not the catch - is what makes this safe. A deployed
  ///      contract whose getter still reverts is the wrong contract, not an unset
  ///      aggregator, so the catch fails closed instead of reading zero.
  function readAggregators(
    address verifier,
    address resolver
  ) public view returns (address verifierAggregator, address resolverAggregator) {
    if (verifier.code.length != 0) {
      try CommitteeVerifier(verifier).getDynamicConfig() returns (
        CommitteeVerifier.DynamicConfig memory dynamicConfig
      ) {
        verifierAggregator = dynamicConfig.feeAggregator;
      } catch {
        revert("SweepFees: verifier getDynamicConfig() reverted - not a CommitteeVerifier at this address?");
      }
    }
    if (resolver.code.length != 0) {
      try VersionedVerifierResolver(resolver).getFeeAggregator() returns (address agg) {
        resolverAggregator = agg;
      } catch {
        revert("SweepFees: resolver getFeeAggregator() reverted - not a VersionedVerifierResolver at this address?");
      }
    }
  }

  /// @notice Validates every configured fee token and returns the ones to stage for
  ///         `target`: those it holds, or all of them when skipZeroBalances is false.
  /// @dev Reverts on the first broken entry - zero, codeless, or not an ERC20. A broken
  ///      entry is a misconfiguration, not an empty balance.
  function sweepableTokens(
    address target,
    address[] memory feeTokens,
    bool skipZeroBalances
  ) public view returns (address[] memory kept) {
    address[] memory buf = new address[](feeTokens.length);
    uint256 n = 0;
    for (uint256 i = 0; i < feeTokens.length; ++i) {
      address token = feeTokens[i];
      require(
        token != address(0),
        string.concat(
          "SweepFees: feeTokens[", vm.toString(i), "] in config/chains is the zero address, fix or remove the entry"
        )
      );
      require(
        token.code.length != 0,
        string.concat(
          "SweepFees: fee token ",
          vm.toString(token),
          " has no code - wrong address in config/chains, or wrong --rpc-url?"
        )
      );
      try IERC20(token).balanceOf(target) returns (uint256 bal) {
        if (!skipZeroBalances || bal > 0) buf[n++] = token;
      } catch {
        revert(string.concat("SweepFees: fee token ", vm.toString(token), " balanceOf reverted - not an ERC20?"));
      }
    }
    kept = new address[](n);
    for (uint256 i = 0; i < n; ++i) {
      kept[i] = buf[i];
    }
  }
}
