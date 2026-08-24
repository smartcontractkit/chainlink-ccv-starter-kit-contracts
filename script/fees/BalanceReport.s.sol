// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title BalanceReport
/// @notice Read-only report of accrued fee-token balances held by the verifier and
///         resolver. Also reads each contract's configured feeAggregator ADDRESS (no
///         aggregator balances): zero means withdrawFeeTokens would revert, a mismatch
///         vs config/roles means a sweep would pay out to an unintended destination.
/// @dev Read-only: no broadcasting, no Safe output. Run without --broadcast.
///
/// Usage:
///   forge script script/fees/BalanceReport.s.sol --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
contract BalanceReport is Script {
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
    for (uint256 i; i < feeTokens.length; ++i) {
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
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    Types.ChainConfig memory chainConfig = ConfigLib.readChain(chainAlias);

    console2.log("[BalanceReport] chain:", chainAlias);
    console2.log("  verifier:", deployment.verifier);
    console2.log("  resolver:", deployment.resolver);

    // ---- fee aggregators (the sweep destinations) ----
    (address vAgg, address rAgg, bool vOk, bool rOk) = readAggregators(deployment.verifier, deployment.resolver);

    if (!vOk) {
      console2.log("  WARN verifier feeAggregator unreadable (not deployed on this chain?)");
    } else if (vAgg == address(0)) {
      console2.log("  WARN verifier feeAggregator is ZERO -> withdrawFeeTokens would REVERT");
    } else {
      console2.log("  verifier feeAggregator:", vAgg);
    }

    if (!rOk) {
      console2.log("  WARN resolver feeAggregator unreadable (not deployed on this chain?)");
    } else if (rAgg == address(0)) {
      console2.log("  WARN resolver feeAggregator is ZERO -> withdrawFeeTokens would REVERT");
    } else {
      console2.log("  resolver feeAggregator:", rAgg);
    }

    // Cross-check the on-chain values against the intended holders in config/roles.
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);
    if (vOk && roles.verifier.feeAggregator != address(0) && vAgg != roles.verifier.feeAggregator) {
      console2.log("  DRIFT verifier feeAggregator != config/roles; expected:", roles.verifier.feeAggregator);
    }
    if (rOk && roles.resolver.feeAggregator != address(0) && rAgg != roles.resolver.feeAggregator) {
      console2.log("  DRIFT resolver feeAggregator != config/roles; expected:", roles.resolver.feeAggregator);
    }

    // ---- balances ----
    if (chainConfig.feeTokens.length == 0) {
      console2.log("  no feeTokens configured for this chain; add them to config/chains/<alias>.json");
      return;
    }

    TokenBalance[] memory balances = readBalances(deployment.verifier, deployment.resolver, chainConfig.feeTokens);
    for (uint256 i; i < balances.length; ++i) {
      console2.log("  token:", balances[i].token);
      if (balances[i].verifierReadOk) {
        console2.log("    verifier balance:", balances[i].verifierBalance);
      } else {
        console2.log("    verifier balance: UNREADABLE (not an ERC20 at this address?)");
      }
      if (balances[i].resolverReadOk) {
        console2.log("    resolver balance:", balances[i].resolverBalance);
      } else {
        console2.log("    resolver balance: UNREADABLE (not an ERC20 at this address?)");
      }
    }
  }
}
