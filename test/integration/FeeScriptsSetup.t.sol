// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Types} from "../../src/lib/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";

/// @title FeeScriptsSetup
/// @notice Shared fixture for the fee scripts. Extends the CCV fixture with two fee
///         tokens, balances accrued on BOTH the verifier and the resolver, and the two
///         DISTINCT fee aggregators actually set on chain.
/// @dev The distinct-aggregator setup is the point: the verifier's lives in
///      DynamicConfig.feeAggregator, the resolver's in its own s_feeAggregator. Tests
///      assert each contract sweeps to its OWN destination.
abstract contract FeeScriptsSetup is CommitteeVerifierSetup {
  MockERC20 internal tokenA;
  MockERC20 internal tokenB;

  address internal constant VERIFIER_AGG = address(0xA11CE);
  address internal constant RESOLVER_AGG = address(0xB0B);

  uint256 internal constant VERIFIER_BAL_A = 100e18;
  uint256 internal constant VERIFIER_BAL_B = 250e18;
  uint256 internal constant RESOLVER_BAL_A = 7e18;

  function setUp() public virtual override {
    super.setUp();

    tokenA = new MockERC20("Fee Token A", "FEEA");
    tokenB = new MockERC20("Fee Token B", "FEEB");

    // Fees accrue inside the contracts themselves.
    tokenA.mint(address(verifier), VERIFIER_BAL_A);
    tokenB.mint(address(verifier), VERIFIER_BAL_B);
    tokenA.mint(address(resolver), RESOLVER_BAL_A);
    // tokenB deliberately NOT minted to the resolver: exercises FeeTokenHandler's
    // zero-balance skip inside an otherwise successful sweep.

    _setVerifierAggregator(VERIFIER_AGG);
    resolver.setFeeAggregator(RESOLVER_AGG);
  }

  /// @dev setDynamicConfig replaces the whole struct, so allowlistAdmin must be re-supplied.
  function _setVerifierAggregator(
    address aggregator
  ) internal {
    verifier.setDynamicConfig(
      CommitteeVerifier.DynamicConfig({feeAggregator: aggregator, allowlistAdmin: address(this)})
    );
  }

  /// @dev Chain config carrying only what the fee scripts read; other fields are
  ///      irrelevant here and left at defaults.
  function _chainConfig(
    address[] memory feeTokens
  ) internal pure returns (Types.ChainConfig memory chainConfig) {
    chainConfig.aliasName = "test_fee_chain";
    chainConfig.feeTokens = feeTokens;
  }

  function _deployment() internal view returns (Types.Deployment memory deployment) {
    deployment.aliasName = "test_fee_chain";
    deployment.factory = address(factory);
    deployment.resolver = address(resolver);
    deployment.verifiers = _verifiersOf(address(verifier));
  }

  function _bothTokens() internal view returns (address[] memory feeTokens) {
    feeTokens = new address[](2);
    feeTokens[0] = address(tokenA);
    feeTokens[1] = address(tokenB);
  }
}
