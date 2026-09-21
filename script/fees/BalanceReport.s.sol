// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @title BalanceReport
/// @notice Read-only report of accrued fee-token balances held by EVERY recorded
///         verifier and the resolver (old verifiers keep accruing fees
///         while they drain). Also reads each contract's configured feeAggregator ADDRESS (no
///         aggregator balances): zero means withdrawFeeTokens would revert, a mismatch
///         vs config/operator/chains/<alias>.json means a sweep would pay out to an unintended destination.
/// @dev Read-only: no broadcasting, no Safe output. Run without --broadcast. Extends
///      BaseScript for its shared preflights only; the staging plumbing goes unused.
///
/// Usage:
///   forge script script/fees/BalanceReport.s.sol --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
contract BalanceReport is BaseScript {
  /// @notice Result for one (contract, token) pair. Returned so tests can assert on
  ///         the report instead of scraping console output.
  struct TokenBalance {
    address token;
    uint256 verifierBalance;
    uint256 resolverBalance;
    bool verifierReadOk;
    bool resolverReadOk;
  }

  /// @notice Reads the on-chain fee aggregator of both contracts.
  /// @return verifierAggregator The verifier's DynamicConfig.feeAggregator (zero if unreadable).
  /// @return resolverAggregator The resolver's s_feeAggregator (zero if unreadable).
  /// @return verifierOk False when the verifier could not be read at all.
  /// @return resolverOk False when the resolver could not be read at all.
  function readAggregators(
    address verifier,
    address resolver
  ) public view returns (address verifierAggregator, address resolverAggregator, bool verifierOk, bool resolverOk) {
    if (verifier.code.length != 0) {
      try CommitteeVerifier(verifier).getDynamicConfig() returns (
        CommitteeVerifier.DynamicConfig memory dynamicConfig
      ) {
        verifierAggregator = dynamicConfig.feeAggregator;
        verifierOk = true;
      } catch {
        verifierOk = false;
      }
    }

    if (resolver.code.length != 0) {
      try VersionedVerifierResolver(resolver).getFeeAggregator() returns (address agg) {
        resolverAggregator = agg;
        resolverOk = true;
      } catch {
        resolverOk = false;
      }
    }
  }

  /// @notice Reads balances of every configured fee token for both contracts.
  function readBalances(
    address verifier,
    address resolver,
    address[] memory feeTokens
  ) public view returns (TokenBalance[] memory balances) {
    balances = new TokenBalance[](feeTokens.length);
    for (uint256 i = 0; i < feeTokens.length; ++i) {
      balances[i].token = feeTokens[i];

      if (verifier.code.length != 0 && feeTokens[i].code.length != 0) {
        try IERC20(feeTokens[i]).balanceOf(verifier) returns (uint256 bal) {
          balances[i].verifierBalance = bal;
          balances[i].verifierReadOk = true;
        } catch {}
      }

      if (resolver.code.length != 0 && feeTokens[i].code.length != 0) {
        try IERC20(feeTokens[i]).balanceOf(resolver) returns (uint256 bal) {
          balances[i].resolverBalance = bal;
          balances[i].resolverReadOk = true;
        } catch {}
      }
    }
  }

  function run(
    string calldata chainAlias
  ) external view {
    ConfigLib.assertChain(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    Types.ChainConfig memory chainConfig = ConfigLib.readChain(chainAlias);
    Types.OperatorConfig memory operator = ConfigLib.readOperator(chainAlias);

    console2.log("[BalanceReport] chain:", chainAlias);
    console2.log("  verifiers recorded:", deployment.verifiers.length);
    console2.log("  resolver:", deployment.resolver);

    // Everything recorded must be reachable; a partial deployment is an error.
    require(deployment.verifiers.length > 0, "BalanceReport: no verifier recorded in config/deployments");
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      _assertReachable(
        deployment.verifiers[i].addr,
        string.concat("verifier ", ConfigLib.tagToString(deployment.verifiers[i].versionTag))
      );
    }
    _assertReachable(deployment.resolver, "resolver");

    // ---- every recorded verifier ----
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      _reportVerifier(deployment.verifiers[i], operator, chainConfig.feeTokens);
    }

    // ---- resolver ----
    // address(0) selects one side: the code-length guard inside skips a zero address.
    (, address rAgg,, bool rOk) = readAggregators(address(0), deployment.resolver);
    if (!rOk) {
      console2.log("  WARN resolver feeAggregator unreadable (not deployed on this chain?)");
    } else if (rAgg == address(0)) {
      console2.log("  WARN resolver feeAggregator is ZERO -> withdrawFeeTokens would REVERT");
    } else {
      console2.log("  resolver feeAggregator:", rAgg);
    }
    if (rOk && operator.resolver.roles.feeAggregator != address(0) && rAgg != operator.resolver.roles.feeAggregator) {
      console2.log(
        "  DRIFT resolver feeAggregator != config/operator/chains/<alias>.json; expected:",
        operator.resolver.roles.feeAggregator
      );
    }

    if (chainConfig.feeTokens.length == 0) {
      console2.log("  no feeTokens configured for this chain; add them to config/chains/<alias>.json");
      return;
    }
    // address(0) selects one side: the code-length guard inside skips a zero address.
    TokenBalance[] memory balances = readBalances(address(0), deployment.resolver, chainConfig.feeTokens);
    for (uint256 i = 0; i < balances.length; ++i) {
      console2.log("  token:", balances[i].token);
      if (balances[i].resolverReadOk) {
        console2.log("    resolver balance:", balances[i].resolverBalance);
      } else {
        console2.log("    resolver balance: UNREADABLE (not an ERC20 at this address?)");
      }
    }
  }

  /// @dev One verifier's aggregator + balances. A report must not revert on a config
  ///      gap, so a missing roles entry is a WARN here (DriftCheck flags it as drift).
  function _reportVerifier(
    Types.VerifierDeployment memory entry,
    Types.OperatorConfig memory operator,
    address[] memory feeTokens
  ) private view {
    console2.log(string.concat("  verifier ", ConfigLib.tagToString(entry.versionTag), ":"), entry.addr);

    // address(0) selects one side: the code-length guard inside skips a zero address.
    (address vAgg,, bool vOk,) = readAggregators(entry.addr, address(0));
    if (!vOk) {
      console2.log("    WARN feeAggregator unreadable (not deployed on this chain?)");
    } else if (vAgg == address(0)) {
      console2.log("    WARN feeAggregator is ZERO -> withdrawFeeTokens would REVERT");
    } else {
      console2.log("    feeAggregator:", vAgg);
    }

    if (!ConfigLib.hasVerifierConfigTag(operator, entry.versionTag)) {
      console2.log("    WARN no roles entry for this versionTag in config/operator/chains/<alias>.json");
    } else {
      address intended = ConfigLib.verifierConfigByTag(operator, entry.versionTag).roles.feeAggregator;
      if (vOk && intended != address(0) && vAgg != intended) {
        console2.log("    DRIFT feeAggregator != config/operator/chains/<alias>.json; expected:", intended);
      }
    }

    TokenBalance[] memory balances = readBalances(entry.addr, address(0), feeTokens);
    for (uint256 i = 0; i < balances.length; ++i) {
      console2.log("    token:", balances[i].token);
      if (balances[i].verifierReadOk) {
        console2.log("      balance:", balances[i].verifierBalance);
      } else {
        console2.log("      balance: UNREADABLE (not an ERC20 at this address?)");
      }
    }
  }
}
