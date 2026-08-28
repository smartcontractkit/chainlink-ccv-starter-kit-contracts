// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BalanceReport} from "../../script/fees/BalanceReport.s.sol";
import {FeeScriptsSetup} from "./FeeScriptsSetup.t.sol";

/// @notice Exercises BalanceReport's read helpers against the real audited contracts.
/// @dev BalanceReport is a DIAGNOSTIC: it must degrade to flags rather than reverting
///      when an address is undeployed or a "fee token" is not an ERC20, because that is
///      precisely the situation an operator runs it to diagnose.
contract BalanceReportTest is FeeScriptsSetup {
  BalanceReport internal script;

  function setUp() public override {
    super.setUp();
    script = new BalanceReport();
  }

  // ---------------------------------------------------------------------------
  //  Aggregators
  // ---------------------------------------------------------------------------

  function test_readAggregators_reportsTheTwoDistinctDestinations() public view {
    (address vAgg, address rAgg, bool vOk, bool rOk) = script.readAggregators(address(verifier), address(resolver));

    assertTrue(vOk, "verifier readable");
    assertTrue(rOk, "resolver readable");
    assertEq(vAgg, VERIFIER_AGG, "verifier aggregator from DynamicConfig");
    assertEq(rAgg, RESOLVER_AGG, "resolver aggregator from s_feeAggregator");
    assertTrue(vAgg != rAgg, "the two aggregators are independent");
  }

  function test_readAggregators_surfacesZeroVerifierAggregator() public {
    _setVerifierAggregator(address(0));

    // the needed tuple element is destructured; the rest is deliberately dropped
    // forge-lint: disable-next-line(unused-return)
    (address vAgg,, bool vOk,) = script.readAggregators(address(verifier), address(resolver));

    assertTrue(vOk, "still readable - the contract exists, the value is just zero");
    assertEq(vAgg, address(0), "zero aggregator reported, not hidden");
  }

  function test_readAggregators_doesNotRevertOnUndeployedAddresses() public view {
    (address vAgg, address rAgg, bool vOk, bool rOk) = script.readAggregators(address(0), address(0));

    assertFalse(vOk, "address(0) is not readable");
    assertFalse(rOk, "address(0) is not readable");
    assertEq(vAgg, address(0));
    assertEq(rAgg, address(0));
  }

  function test_readAggregators_doesNotRevertOnNonContract() public view {
    // An EOA at a plausible-looking address: the report must flag, not abort.
    // the needed tuple element is destructured; the rest is deliberately dropped
    // forge-lint: disable-next-line(unused-return)
    (,, bool vOk, bool rOk) = script.readAggregators(address(0xDEADBEEF), address(0xFEEDFACE));

    assertFalse(vOk, "non-contract flagged unreadable");
    assertFalse(rOk, "non-contract flagged unreadable");
  }

  // ---------------------------------------------------------------------------
  //  Balances
  // ---------------------------------------------------------------------------

  function test_readBalances_reportsPerTokenPerContract() public view {
    BalanceReport.TokenBalance[] memory balances =
      script.readBalances(address(verifier), address(resolver), _bothTokens());

    assertEq(balances.length, 2, "one row per fee token");

    assertEq(balances[0].token, address(tokenA));
    assertEq(balances[0].verifierBalance, VERIFIER_BAL_A);
    assertEq(balances[0].resolverBalance, RESOLVER_BAL_A);
    assertTrue(balances[0].verifierReadOk && balances[0].resolverReadOk);

    assertEq(balances[1].token, address(tokenB));
    assertEq(balances[1].verifierBalance, VERIFIER_BAL_B);
    assertEq(balances[1].resolverBalance, 0, "resolver never accrued tokenB");
    assertTrue(balances[1].verifierReadOk && balances[1].resolverReadOk);
  }

  function test_readBalances_flagsUnreadableToken() public view {
    address[] memory bogus = new address[](1);
    bogus[0] = address(0xBADC0DE); // not an ERC20

    BalanceReport.TokenBalance[] memory balances = script.readBalances(address(verifier), address(resolver), bogus);

    assertEq(balances.length, 1);
    assertFalse(balances[0].verifierReadOk, "must flag rather than revert");
    assertFalse(balances[0].resolverReadOk, "must flag rather than revert");
    assertEq(balances[0].verifierBalance, 0);
  }

  function test_readBalances_skipsUndeployedContract() public view {
    BalanceReport.TokenBalance[] memory balances = script.readBalances(address(0), address(resolver), _bothTokens());

    assertFalse(balances[0].verifierReadOk, "no verifier to read");
    assertTrue(balances[0].resolverReadOk, "resolver still reported");
    assertEq(balances[0].resolverBalance, RESOLVER_BAL_A);
  }

  function test_readBalances_emptyTokenListIsEmptyReport() public view {
    BalanceReport.TokenBalance[] memory balances =
      script.readBalances(address(verifier), address(resolver), new address[](0));

    assertEq(balances.length, 0);
  }
}
