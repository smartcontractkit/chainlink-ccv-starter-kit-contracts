// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";

/// @title BalanceReport
/// @notice Outline step 15. Read-only report of accrued fee-token balances held by
///         the verifier and resolver, plus a zero-feeAggregator check so an operator
///         knows whether a sweep would revert before attempting it.
/// @dev Read-only: no broadcasting, no Safe output. Run without --broadcast.
///
/// Usage:
///   forge script script/fees/BalanceReport.s.sol --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
contract BalanceReport is Script {
  function run(string calldata chainAlias) external view {
    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);

    console2.log("[BalanceReport] chain:", chainAlias);
    console2.log("  verifier:", dep.verifier);
    console2.log("  resolver:", dep.resolver);

    // TODO(step 15): for each fee token in config, read ERC20 balanceOf(dep.verifier)
    //   and balanceOf(dep.resolver) and log them. Also read each contract's on-chain
    //   feeAggregator getter and flag any that are zero (sweep would revert).
    //   Example:
    //     for (uint256 i; i < feeTokens.length; ++i) {
    //       uint256 vBal = IERC20(feeTokens[i]).balanceOf(dep.verifier);
    //       uint256 rBal = IERC20(feeTokens[i]).balanceOf(dep.resolver);
    //       console2.log("  token", feeTokens[i]);
    //       console2.log("    verifier balance:", vBal);
    //       console2.log("    resolver balance:", rBal);
    //     }
  }
}
