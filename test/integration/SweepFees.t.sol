// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SweepFees} from "../../script/fees/SweepFees.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {Types} from "../../src/lib/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FeeScriptsSetup} from "./FeeScriptsSetup.t.sol";
import {FeeTokenHandler} from "@chainlink/contracts-ccip/contracts/libraries/FeeTokenHandler.sol";

/// @notice Exercises SweepFees through `sweepCalls`, the same seam `run()` uses, against
///         the real audited contracts. The skip logic is the whole point: a zero
///         feeAggregator makes withdrawFeeTokens revert unconditionally
///         (FeeTokenHandler:21 checks before the loop), so emitting such a call would
///         hand signers a Safe batch that fails on execution.
contract SweepFeesTest is FeeScriptsSetup {
  SweepFees internal script;

  function setUp() public override {
    super.setUp();
    script = new SweepFees();
  }

  // ---------------------------------------------------------------------------
  //  Which contracts get swept
  // ---------------------------------------------------------------------------

  function test_sweepCalls_includesBothWhenAggregatorsSet() public view {
    (BaseScript.Call[] memory calls, SweepFees.SkipReason skipV, SweepFees.SkipReason skipR) =
      script.sweepCalls(_deployment(), _chainConfig(_bothTokens()), false);

    assertEq(calls.length, 2, "verifier + resolver");
    assertEq(calls[0].to, address(verifier), "verifier first");
    assertEq(calls[1].to, address(resolver), "resolver second");
    assertTrue(skipV == SweepFees.SkipReason.None, "verifier not skipped");
    assertTrue(skipR == SweepFees.SkipReason.None, "resolver not skipped");
  }

  function test_sweepCalls_skipsVerifierWhenItsAggregatorIsZero() public {
    _setVerifierAggregator(address(0));

    (BaseScript.Call[] memory calls, SweepFees.SkipReason skipV, SweepFees.SkipReason skipR) =
      script.sweepCalls(_deployment(), _chainConfig(_bothTokens()), false);

    assertEq(calls.length, 1, "only the resolver is sweepable");
    assertEq(calls[0].to, address(resolver), "surviving call targets the resolver");
    assertTrue(skipV == SweepFees.SkipReason.NoAggregator, "verifier skipped: would revert");
    assertTrue(skipR == SweepFees.SkipReason.None, "resolver still swept - aggregators are independent");
  }

  function test_sweepCalls_skipsResolverWhenItsAggregatorIsZero() public {
    resolver.setFeeAggregator(address(0));

    (BaseScript.Call[] memory calls, SweepFees.SkipReason skipV, SweepFees.SkipReason skipR) =
      script.sweepCalls(_deployment(), _chainConfig(_bothTokens()), false);

    assertEq(calls.length, 1, "only the verifier is sweepable");
    assertEq(calls[0].to, address(verifier), "surviving call targets the verifier");
    assertTrue(skipV == SweepFees.SkipReason.None, "verifier still swept");
    assertTrue(skipR == SweepFees.SkipReason.NoAggregator, "resolver skipped: would revert");
  }

  function test_sweepCalls_isNoopWhenNoFeeTokensConfigured() public view {
    (BaseScript.Call[] memory calls, SweepFees.SkipReason skipV, SweepFees.SkipReason skipR) =
      script.sweepCalls(_deployment(), _chainConfig(new address[](0)), false);

    assertEq(calls.length, 0, "nothing to sweep");
    assertTrue(skipV == SweepFees.SkipReason.NoBalance, "no tokens configured = nothing to move");
    assertTrue(skipR == SweepFees.SkipReason.NoBalance, "no tokens configured = nothing to move");
  }

  function test_sweepCalls_skipsUndeployedContracts() public view {
    Types.Deployment memory deployment = _deployment();
    deployment.verifier = address(0); // not deployed on this chain yet

    (BaseScript.Call[] memory calls, SweepFees.SkipReason skipV, SweepFees.SkipReason skipR) =
      script.sweepCalls(deployment, _chainConfig(_bothTokens()), false);

    assertEq(calls.length, 1);
    assertEq(calls[0].to, address(resolver));
    assertTrue(skipV == SweepFees.SkipReason.NoAggregator, "unrecorded verifier skipped, not addressed as address(0)");
    assertTrue(skipR == SweepFees.SkipReason.None);
  }

  // ---------------------------------------------------------------------------
  //  SKIP_ZERO_BALANCES: optional whole-contract skip when nothing would move
  // ---------------------------------------------------------------------------

  /// @dev Only the resolver holds tokenC, so under the flag the verifier is skipped as
  ///      NoBalance - a different reason than NoAggregator, so run() logs it honestly.
  function test_skipZeroBalances_skipsContractHoldingNothing() public {
    MockERC20 tokenC = new MockERC20("Fee Token C", "FEEC");
    tokenC.mint(address(resolver), 1e18);
    address[] memory onlyC = new address[](1);
    onlyC[0] = address(tokenC);

    (BaseScript.Call[] memory calls, SweepFees.SkipReason skipV, SweepFees.SkipReason skipR) =
      script.sweepCalls(_deployment(), _chainConfig(onlyC), true);

    assertEq(calls.length, 1, "only the funded contract is staged");
    assertEq(calls[0].to, address(resolver));
    assertTrue(skipV == SweepFees.SkipReason.NoBalance, "verifier skipped: nothing to move, not a revert risk");
    assertTrue(skipR == SweepFees.SkipReason.None);
  }

  /// @dev Default (flag off): a zero-balance contract is STILL staged - batches must not
  ///      depend on volatile balances unless the operator opts in.
  function test_skipZeroBalances_offByDefault_stagesZeroBalanceContract() public {
    MockERC20 tokenC = new MockERC20("Fee Token C", "FEEC");
    tokenC.mint(address(resolver), 1e18);
    address[] memory onlyC = new address[](1);
    onlyC[0] = address(tokenC);

    (
      BaseScript.Call[] memory calls,
      SweepFees.SkipReason skipV,
      // called for its expected revert; the return is irrelevant
      // forge-lint: disable-next-line(unused-return)
    ) = script.sweepCalls(_deployment(), _chainConfig(onlyC), false);

    assertEq(calls.length, 2, "both staged regardless of balances");
    assertTrue(skipV == SweepFees.SkipReason.None, "zero balance is not a skip when the flag is off");
  }

  /// @dev The flag must never skip a funded contract.
  function test_skipZeroBalances_doesNotSkipFundedContracts() public view {
    (BaseScript.Call[] memory calls, SweepFees.SkipReason skipV, SweepFees.SkipReason skipR) =
      script.sweepCalls(_deployment(), _chainConfig(_bothTokens()), true);

    assertEq(calls.length, 2, "both hold balances; both staged");
    assertTrue(skipV == SweepFees.SkipReason.None);
    assertTrue(skipR == SweepFees.SkipReason.None);
  }

  // ---------------------------------------------------------------------------
  //  Executing the sweep
  // ---------------------------------------------------------------------------

  function test_executingSweep_movesBalancesToEachContractsOwnAggregator() public {
    // the needed tuple element is destructured; the rest is deliberately dropped
    // forge-lint: disable-next-line(unused-return)
    (BaseScript.Call[] memory calls,,) = script.sweepCalls(_deployment(), _chainConfig(_bothTokens()), false);

    for (uint256 i = 0; i < calls.length; ++i) {
      (bool ok,) = calls[i].to.call(calls[i].data); // permissionless, any sender
      assertTrue(ok, "sweep call reverted");
    }

    // Verifier balances went to the VERIFIER's aggregator...
    assertEq(tokenA.balanceOf(VERIFIER_AGG), VERIFIER_BAL_A, "tokenA -> verifier aggregator");
    assertEq(tokenB.balanceOf(VERIFIER_AGG), VERIFIER_BAL_B, "tokenB -> verifier aggregator");
    assertEq(tokenA.balanceOf(address(verifier)), 0, "verifier drained of tokenA");
    assertEq(tokenB.balanceOf(address(verifier)), 0, "verifier drained of tokenB");

    // ...and resolver balances to the RESOLVER's, which is a different address.
    assertEq(tokenA.balanceOf(RESOLVER_AGG), RESOLVER_BAL_A, "tokenA -> resolver aggregator");
    assertEq(tokenA.balanceOf(address(resolver)), 0, "resolver drained of tokenA");

    // The two destinations must not be conflated.
    assertEq(tokenB.balanceOf(RESOLVER_AGG), 0, "resolver had no tokenB to sweep");
    assertTrue(VERIFIER_AGG != RESOLVER_AGG, "fixture must use distinct aggregators");
  }

  /// @dev Proves the skip logic earns its keep: the call SweepFees declines to emit is
  ///      exactly the one that reverts. Built via `callsFor` to bypass the guard.
  function test_sweepingWithZeroAggregator_revertsOnChain() public {
    _setVerifierAggregator(address(0));

    BaseScript.Call memory call = script.callsFor(address(verifier), _bothTokens());

    vm.expectRevert(FeeTokenHandler.ZeroAddressNotAllowed.selector);
    (bool ok,) = call.to.call(call.data);
    ok; // silence unused; expectRevert asserts the outcome
  }

  /// @dev FeeTokenHandler skips zero balances inside an otherwise successful sweep, so a
  ///      token the contract never accrued is harmless in the list.
  function test_sweepTolerates_tokenWithZeroBalance() public {
    BaseScript.Call memory call = script.callsFor(address(resolver), _bothTokens());

    (bool ok,) = call.to.call(call.data);
    assertTrue(ok, "zero-balance token must not revert the sweep");
    assertEq(tokenA.balanceOf(RESOLVER_AGG), RESOLVER_BAL_A);
    assertEq(tokenB.balanceOf(RESOLVER_AGG), 0);
  }
}
