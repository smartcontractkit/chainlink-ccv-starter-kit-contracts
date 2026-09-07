// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SweepFees} from "../../script/fees/SweepFees.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {Types} from "../../src/lib/Types.sol";
import {FeeScriptsSetup} from "./FeeScriptsSetup.t.sol";

/// @notice Exercises buildSweepBatch - the composed config-in, batch-out seam run()
///         drives - and its parts, against the real audited contracts. The only
///         untested gates are run()'s recorded-deployment and reachability requires.
contract SweepFeesTest is FeeScriptsSetup {
  SweepFees internal script;

  function setUp() public override {
    super.setUp();
    script = new SweepFees();
  }

  // ---------------------------------------------------------------------------
  //  sweepableTokens: entry validation
  // ---------------------------------------------------------------------------

  function test_sweepableTokens_revertsOnZeroAddress() public {
    address[] memory tokens = _bothTokens();
    tokens[1] = address(0);

    vm.expectRevert(bytes("SweepFees: feeTokens[1] in config/chains is the zero address, fix or remove the entry"));
    // the expected revert is the assertion; the return never materialises
    // forge-lint: disable-next-line(unused-return)
    script.sweepableTokens(address(verifier), tokens, true);
  }

  function test_sweepableTokens_revertsOnCodelessToken() public {
    address ghost = address(0x60057);
    address[] memory tokens = new address[](1);
    tokens[0] = ghost;

    vm.expectRevert(
      bytes(
        string.concat(
          "SweepFees: fee token ",
          vm.toString(ghost),
          " has no code - wrong address in config/chains, or wrong --rpc-url?"
        )
      )
    );
    // the expected revert is the assertion; the return never materialises
    // forge-lint: disable-next-line(unused-return)
    script.sweepableTokens(address(verifier), tokens, true);
  }

  /// @dev An address with code that is not an ERC20 (here: the resolver itself) must be
  ///      rejected at build time instead of reverting the withdraw on-chain.
  function test_sweepableTokens_revertsOnNonErc20() public {
    address[] memory tokens = new address[](1);
    tokens[0] = address(resolver);

    vm.expectRevert(
      bytes(
        string.concat("SweepFees: fee token ", vm.toString(address(resolver)), " balanceOf reverted - not an ERC20?")
      )
    );
    // the expected revert is the assertion; the return never materialises
    // forge-lint: disable-next-line(unused-return)
    script.sweepableTokens(address(verifier), tokens, true);
  }

  // ---------------------------------------------------------------------------
  //  sweepableTokens: the SKIP_ZERO_BALANCES filter
  // ---------------------------------------------------------------------------

  function test_sweepableTokens_keepsOnlyHeldTokens() public view {
    address[] memory verifierKept = script.sweepableTokens(address(verifier), _bothTokens(), true);
    assertEq(verifierKept.length, 2, "verifier holds tokenA and tokenB");
    assertEq(verifierKept[0], address(tokenA));
    assertEq(verifierKept[1], address(tokenB));

    address[] memory resolverKept = script.sweepableTokens(address(resolver), _bothTokens(), true);
    assertEq(resolverKept.length, 1, "resolver holds only tokenA");
    assertEq(resolverKept[0], address(tokenA));
  }

  function test_sweepableTokens_emptyWhenTargetHoldsNothing() public view {
    address[] memory kept = script.sweepableTokens(address(0xFEE), _bothTokens(), true);
    assertEq(kept.length, 0, "no balances, nothing kept");
  }

  /// @dev Flag off: every configured token is staged regardless of balance, so a batch
  ///      executed much later also sweeps fees that accrue in between.
  function test_sweepableTokens_disabledFlagKeepsAllTokens() public view {
    address[] memory kept = script.sweepableTokens(address(0xFEE), _bothTokens(), false);
    assertEq(kept.length, 2, "flag off: full list, balances ignored");
    assertEq(kept[0], address(tokenA));
    assertEq(kept[1], address(tokenB));
  }

  // ---------------------------------------------------------------------------
  //  buildSweepBatch: config + chain state in, the whole batch out
  // ---------------------------------------------------------------------------

  function _rolesWithAggregators(
    address verifierAggregator,
    address resolverAggregator
  ) private pure returns (Types.RolesConfig memory roles) {
    roles.verifiers = new Types.VerifierRoles[](1);
    roles.verifiers[0].versionTag = VERSION_TAG;
    roles.verifiers[0].feeAggregator = verifierAggregator;
    roles.resolver.feeAggregator = resolverAggregator;
  }

  function test_batch_stagesBothWhenFullyConfigured() public view {
    BaseScript.Call[] memory calls =
      script.buildSweepBatch(_deployment(), _rolesWithAggregators(VERIFIER_AGG, RESOLVER_AGG), _bothTokens(), true);

    assertEq(calls.length, 2, "verifier + resolver");
    assertEq(calls[0].to, address(verifier), "verifier first");
    assertEq(calls[1].to, address(resolver), "resolver second");
    assertEq(
      keccak256(calls[0].data),
      keccak256(script.buildWithdrawCall(address(verifier), _bothTokens()).data),
      "verifier sweeps both held tokens"
    );

    // The batch must carry the FILTERED list: the resolver holds no tokenB, and the
    // executing test cannot catch this (the on-chain withdraw skips zeros anyway).
    address[] memory onlyA = new address[](1);
    onlyA[0] = address(tokenA);
    assertEq(
      keccak256(calls[1].data),
      keccak256(script.buildWithdrawCall(address(resolver), onlyA).data),
      "resolver call omits the token it does not hold"
    );
  }

  /// @dev The point of per-contract gating: the verifier not being in use (no aggregator
  ///      on-chain or in config) must not block the resolver's accrued fees, and vice versa.
  function test_batch_unusedVerifierDoesNotBlockResolver() public {
    _setVerifierAggregator(address(0));

    BaseScript.Call[] memory calls =
      script.buildSweepBatch(_deployment(), _rolesWithAggregators(address(0), RESOLVER_AGG), _bothTokens(), true);

    assertEq(calls.length, 1, "verifier skipped, resolver staged");
    assertEq(calls[0].to, address(resolver));
  }

  function test_batch_unusedResolverDoesNotBlockVerifier() public {
    resolver.setFeeAggregator(address(0));

    BaseScript.Call[] memory calls =
      script.buildSweepBatch(_deployment(), _rolesWithAggregators(VERIFIER_AGG, address(0)), _bothTokens(), true);

    assertEq(calls.length, 1, "resolver skipped, verifier staged");
    assertEq(calls[0].to, address(verifier));
  }

  /// @dev A contract holding nothing is skipped without blocking the other either.
  function test_batch_noBalanceSkipsOnlyThatContract() public view {
    address[] memory onlyB = new address[](1);
    onlyB[0] = address(tokenB); // the resolver holds only tokenA

    BaseScript.Call[] memory calls =
      script.buildSweepBatch(_deployment(), _rolesWithAggregators(VERIFIER_AGG, RESOLVER_AGG), onlyB, true);

    assertEq(calls.length, 1, "resolver has no tokenB; verifier staged");
    assertEq(calls[0].to, address(verifier));
  }

  function test_batch_emptyWhenNothingSweepable() public {
    _setVerifierAggregator(address(0));
    resolver.setFeeAggregator(address(0));

    BaseScript.Call[] memory calls =
      script.buildSweepBatch(_deployment(), _rolesWithAggregators(address(0), address(0)), _bothTokens(), true);

    assertEq(calls.length, 0, "both skipped: nothing sweepable");
  }

  /// @dev Fees accrue on old verifiers from in-flight messages while they drain, so
  ///      the batch must cover EVERY recorded verifier, each with the filtered token
  ///      list it actually holds.
  function test_batch_sweepsEveryVerifier() public {
    _deploySecondVerifier(); // its constructor aggregator is FEE_AGGREGATOR
    tokenA.mint(address(verifierV2), 5e18); // gen 2 holds only tokenA

    Types.Deployment memory deployment = _deployment();
    deployment.verifiers = new Types.VerifierDeployment[](2);
    deployment.verifiers[0].versionTag = VERSION_TAG;
    deployment.verifiers[0].addr = address(verifier);
    deployment.verifiers[1].versionTag = VERSION_TAG_V2;
    deployment.verifiers[1].addr = address(verifierV2);
    Types.RolesConfig memory roles = _rolesWithAggregators(VERIFIER_AGG, RESOLVER_AGG);
    roles.verifiers = new Types.VerifierRoles[](2);
    roles.verifiers[0].versionTag = VERSION_TAG;
    roles.verifiers[0].feeAggregator = VERIFIER_AGG;
    roles.verifiers[1].versionTag = VERSION_TAG_V2;
    roles.verifiers[1].feeAggregator = FEE_AGGREGATOR;

    BaseScript.Call[] memory calls = script.buildSweepBatch(deployment, roles, _bothTokens(), true);

    assertEq(calls.length, 3, "verifier 1 + verifier 2 + resolver");
    assertEq(calls[0].to, address(verifier), "verifier 1 first");
    assertEq(calls[1].to, address(verifierV2), "verifier 2 second");
    assertEq(calls[2].to, address(resolver), "resolver last");

    address[] memory onlyA = new address[](1);
    onlyA[0] = address(tokenA);
    assertEq(
      keccak256(calls[1].data),
      keccak256(script.buildWithdrawCall(address(verifierV2), onlyA).data),
      "verifier 2 sweeps only the token it holds"
    );
  }

  /// @dev A recorded verifier with no roles entry cannot be aggregator-checked, so the
  ///      whole sweep fails closed rather than skipping it silently.
  function test_batch_revertsWhenVerifierHasNoRolesEntry() public {
    _deploySecondVerifier();

    Types.Deployment memory deployment = _deployment();
    deployment.verifiers = new Types.VerifierDeployment[](2);
    deployment.verifiers[0].versionTag = VERSION_TAG;
    deployment.verifiers[0].addr = address(verifier);
    deployment.verifiers[1].versionTag = VERSION_TAG_V2;
    deployment.verifiers[1].addr = address(verifierV2);
    Types.RolesConfig memory roles = _rolesWithAggregators(VERIFIER_AGG, RESOLVER_AGG);
    roles.aliasName = "test_fee_chain"; // only verifier 1 declared

    vm.expectRevert(
      bytes(
        "ConfigLib: no verifier roles for versionTag 0x00010002 in config/roles/test_fee_chain.json"
        " - declare that verifier's roles first"
      )
    );
    // the expected revert is the assertion; the return never materialises
    // forge-lint: disable-next-line(unused-return)
    script.buildSweepBatch(deployment, roles, _bothTokens(), true);
  }

  function test_batch_revertsOnUndeclaredIntent() public {
    vm.expectRevert(
      bytes("SweepFees: verifier 0x00010001 feeAggregator is not declared in config/roles - declare it before sweeping")
    );
    // the expected revert is the assertion; the return never materialises
    // forge-lint: disable-next-line(unused-return)
    script.buildSweepBatch(_deployment(), _rolesWithAggregators(address(0), RESOLVER_AGG), _bothTokens(), true);
  }

  /// @dev An unset on-chain aggregator with one intended in config/roles is drift
  ///      like any other mismatch, not a skippable state.
  function test_batch_revertsOnIntendedButUnsetAggregator() public {
    _setVerifierAggregator(address(0));

    vm.expectRevert(
      bytes(
        string.concat(
          "SweepFees: verifier 0x00010001 feeAggregator on-chain ",
          vm.toString(address(0)),
          " does not match config/roles ",
          vm.toString(VERIFIER_AGG)
        )
      )
    );
    // the expected revert is the assertion; the return never materialises
    // forge-lint: disable-next-line(unused-return)
    script.buildSweepBatch(_deployment(), _rolesWithAggregators(VERIFIER_AGG, RESOLVER_AGG), _bothTokens(), true);
  }

  function test_batch_revertsOnAggregatorDrift() public {
    vm.expectRevert(
      bytes(
        string.concat(
          "SweepFees: resolver feeAggregator on-chain ",
          vm.toString(RESOLVER_AGG),
          " does not match config/roles ",
          vm.toString(address(0xD41F7))
        )
      )
    );
    // the expected revert is the assertion; the return never materialises
    // forge-lint: disable-next-line(unused-return)
    script.buildSweepBatch(_deployment(), _rolesWithAggregators(VERIFIER_AGG, address(0xD41F7)), _bothTokens(), true);
  }

  /// @dev A deployed contract whose getter reverts is the wrong contract at the
  ///      recorded address, not an unset aggregator.
  function test_readAggregators_revertsOnWrongContract() public {
    vm.expectRevert(bytes("SweepFees: verifier getDynamicConfig() reverted - not a CommitteeVerifier at this address?"));
    // the expected revert is the assertion; the return never materialises
    // forge-lint: disable-next-line(unused-return)
    script.readAggregators(address(tokenA), address(resolver));
  }

  // ---------------------------------------------------------------------------
  //  Executing the sweep
  // ---------------------------------------------------------------------------

  function test_executingSweep_movesBalancesToEachContractsOwnAggregator() public {
    BaseScript.Call[] memory calls =
      script.buildSweepBatch(_deployment(), _rolesWithAggregators(VERIFIER_AGG, RESOLVER_AGG), _bothTokens(), true);

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

  /// @dev FeeTokenHandler skips zero balances inside an otherwise successful sweep, so a
  ///      token the contract never accrued is harmless in the list (the
  ///      SKIP_ZERO_BALANCES=false path stages exactly such lists).
  function test_sweepTolerates_tokenWithZeroBalance() public {
    BaseScript.Call memory call = script.buildWithdrawCall(address(resolver), _bothTokens());

    (bool ok,) = call.to.call(call.data);
    assertTrue(ok, "zero-balance token must not revert the sweep");
    assertEq(tokenA.balanceOf(RESOLVER_AGG), RESOLVER_BAL_A);
    assertEq(tokenB.balanceOf(RESOLVER_AGG), 0);
  }
}
