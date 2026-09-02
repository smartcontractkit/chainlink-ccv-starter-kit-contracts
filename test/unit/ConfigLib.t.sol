// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Library internals revert in the caller's frame, so expectRevert needs this
///      external-call indirection.
contract ChainAssertHarness {
  function assertChain(
    string calldata aliasName
  ) external view {
    ConfigLib.assertChain(aliasName);
  }

  function assertChainMatches(
    Types.ChainConfig calldata chainConfig,
    string calldata aliasName
  ) external view {
    ConfigLib.assertChainMatches(chainConfig, aliasName);
  }
}

/// @notice Unit tests for the config-as-data loader. Uses the shipped example files
///         directly (path-based) so it does not depend on operator-specific configs.
contract ConfigLibTest is Test {
  string internal constant LANE_EXAMPLE = "config/lanes/sepolia-to-base_sepolia.example.json";

  function test_readLaneByPath_parsesExample() public view {
    Types.LaneConfig memory lane = ConfigLib.readLaneByPath(LANE_EXAMPLE);

    assertEq(lane.name, "sepolia-to-base_sepolia");
    assertEq(lane.source.aliasName, "sepolia");
    assertEq(lane.source.chainSelector, 16015286601757825753);
    assertEq(lane.dest.aliasName, "base_sepolia");
    assertEq(lane.dest.chainSelector, 10344971235874465080);

    // Signature config must respect the "not 1-of-1, threshold > 2/3" constraint.
    assertEq(lane.signatureConfig.threshold, 7);
    assertEq(lane.signatureConfig.signers.length, 10);
    assertGt(lane.signatureConfig.threshold, 1); // not 1-of-1
    assertGt(uint256(lane.signatureConfig.threshold) * 3, lane.signatureConfig.signers.length * 2); // > 2/3
  }

  function test_listLanes_skipsTemplatesAndExamples() public view {
    // Every listed path must be a .json and must NOT be a template or example,
    // regardless of how many real (gitignored) lane files exist locally.
    string[] memory lanes = ConfigLib.listLanes();
    for (uint256 i = 0; i < lanes.length; ++i) {
      assertTrue(_endsWithJson(lanes[i]), "listed path must end in .json");
      assertFalse(_contains(lanes[i], "_template"), "must skip _template files");
      assertFalse(_contains(lanes[i], ".example."), "must skip .example files");
    }
  }

  // ---------------------------------------------------------------------------
  //  chain-identity preflight (assertChain / assertChainMatches)
  // ---------------------------------------------------------------------------

  function test_assertChain_missingConfig_reverts() public {
    ChainAssertHarness h = new ChainAssertHarness();
    vm.expectRevert(bytes("ConfigLib: no chain config at config/chains/zz-no-such-chain.json"));
    h.assertChain("zz-no-such-chain");
  }

  /// @dev The example files double as a real mismatch: sepolia.example.json exists at
  ///      that alias but declares "sepolia" inside.
  function test_assertChain_aliasMismatch_reverts() public {
    ChainAssertHarness h = new ChainAssertHarness();
    vm.expectRevert(bytes("ConfigLib: config/chains/sepolia.example.json declares alias 'sepolia'"));
    h.assertChain("sepolia.example");
  }

  function test_assertChainMatches_zeroChainId_reverts() public {
    ChainAssertHarness h = new ChainAssertHarness();
    vm.expectRevert(bytes("ConfigLib: config/chains/sepolia.json has no chainId"));
    h.assertChainMatches(_chain("sepolia", 0), "sepolia");
  }

  function test_assertChainMatches_connectedToConfiguredChain_passes() public {
    ChainAssertHarness h = new ChainAssertHarness();
    vm.chainId(11155111);
    h.assertChainMatches(_chain("sepolia", 11155111), "sepolia");
  }

  /// @dev The check this feature exists for: a valid config against the wrong RPC.
  ///      CREATE2 puts contracts at the SAME address per chain, so nothing else catches it.
  function test_assertChainMatches_wrongNetwork_reverts() public {
    ChainAssertHarness h = new ChainAssertHarness();
    vm.chainId(84532); // base_sepolia RPC behind a sepolia alias
    vm.expectRevert(bytes("ConfigLib: connected to chain 84532 but sepolia is chain 11155111"));
    h.assertChainMatches(_chain("sepolia", 11155111), "sepolia");
  }

  /// @dev Every script requires a live RPC, and without --rpc-url forge sits at 31337 —
  ///      so a real-chain config at 31337 fails with the missing-flag hint, not a skip.
  function test_assertChainMatches_withoutRpc_reverts() public {
    ChainAssertHarness h = new ChainAssertHarness();
    vm.expectRevert(bytes("ConfigLib: chainid is 31337 but sepolia is chain 11155111 - no --rpc-url passed?"));
    h.assertChainMatches(_chain("sepolia", 11155111), "sepolia");
  }

  /// @dev A config genuinely FOR 31337 (a local anvil chain) is not the skip case: it is
  ///      compared like any other chain, both when it matches and when the run is elsewhere.
  function test_assertChainMatches_localAnvilConfig_isStillCompared() public {
    ChainAssertHarness h = new ChainAssertHarness();
    h.assertChainMatches(_chain("localchain", 31337), "localchain"); // test EVM is 31337: a real match

    vm.chainId(11155111);
    vm.expectRevert(bytes("ConfigLib: connected to chain 11155111 but localchain is chain 31337"));
    h.assertChainMatches(_chain("localchain", 31337), "localchain");
  }

  function _chain(
    string memory aliasName,
    uint256 chainId
  ) private pure returns (Types.ChainConfig memory chainConfig) {
    chainConfig.aliasName = aliasName;
    chainConfig.chainId = chainId;
  }

  function _endsWithJson(
    string memory s
  ) private pure returns (bool) {
    bytes memory b = bytes(s);
    if (b.length < 5) return false;
    return b[b.length - 5] == "." && b[b.length - 4] == "j" && b[b.length - 3] == "s" && b[b.length - 2] == "o"
      && b[b.length - 1] == "n";
  }

  function _contains(
    string memory s,
    string memory needle
  ) private pure returns (bool) {
    bytes memory b = bytes(s);
    bytes memory n = bytes(needle);
    if (n.length == 0 || n.length > b.length) return false;
    for (uint256 i = 0; i <= b.length - n.length; ++i) {
      bool ok = true;
      for (uint256 j = 0; j < n.length; ++j) {
        if (b[i + j] != n[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return true;
    }
    return false;
  }
}
