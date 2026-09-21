// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Test} from "forge-std/Test.sol";

/// @title SortPathsTest
/// @notice `listLanes` sorts because the lane-iterating configure scripts stage every
///         lane into ONE Safe batch, and `ApplyOutboundImplementationUpdates` puts them
///         in a single call's argument array. Unsorted, two operators generate
///         byte-different batches for identical config.
/// @dev The sort is unreachable through `listLanes` in CI: a clean checkout has only
///      `_template.json` and `*.example.json` in `config/operator/lanes/`, both filtered out.
contract SortPathsTest is Test {
  function test_alreadySorted_isUnchanged() public pure {
    string[] memory p =
      _paths("config/operator/lanes/a.json", "config/operator/lanes/b.json", "config/operator/lanes/c.json");
    ConfigLib.sortPaths(p);
    _assertOrder(p, "config/operator/lanes/a.json", "config/operator/lanes/b.json", "config/operator/lanes/c.json");
  }

  function test_reversed_isSorted() public pure {
    string[] memory p =
      _paths("config/operator/lanes/c.json", "config/operator/lanes/b.json", "config/operator/lanes/a.json");
    ConfigLib.sortPaths(p);
    _assertOrder(p, "config/operator/lanes/a.json", "config/operator/lanes/b.json", "config/operator/lanes/c.json");
  }

  /// @dev The property the sort exists for: any input permutation yields one output.
  function test_anyPermutation_yieldsSameOrder() public pure {
    string[] memory a = _paths("m.json", "a.json", "z.json");
    string[] memory b = _paths("z.json", "m.json", "a.json");
    string[] memory c = _paths("a.json", "z.json", "m.json");
    ConfigLib.sortPaths(a);
    ConfigLib.sortPaths(b);
    ConfigLib.sortPaths(c);
    _assertOrder(a, "a.json", "m.json", "z.json");
    _assertOrder(b, "a.json", "m.json", "z.json");
    _assertOrder(c, "a.json", "m.json", "z.json");
  }

  /// @dev A shorter string that prefixes a longer one sorts first — the comparator falls
  ///      through to length only after every shared byte matches.
  function test_prefixSortsBeforeLongerString() public pure {
    string[] memory p = _paths("ab.json", "a.json", "abc.json");
    ConfigLib.sortPaths(p);
    _assertOrder(p, "a.json", "ab.json", "abc.json");
  }

  /// @dev Realistic lane names, where both directions of one pair exist.
  function test_bidirectionalLanePair() public pure {
    string[] memory p = _paths(
      "config/operator/lanes/sepolia-to-base_sepolia.json",
      "config/operator/lanes/base_sepolia-to-sepolia.json",
      "config/operator/lanes/arbitrum_sepolia-to-sepolia.json"
    );
    ConfigLib.sortPaths(p);
    _assertOrder(
      p,
      "config/operator/lanes/arbitrum_sepolia-to-sepolia.json",
      "config/operator/lanes/base_sepolia-to-sepolia.json",
      "config/operator/lanes/sepolia-to-base_sepolia.json"
    );
  }

  /// @dev Byte-wise, not case-insensitive: uppercase (0x41-0x5A) precedes lowercase.
  function test_comparisonIsByteWise() public pure {
    string[] memory p = _paths("b.json", "A.json");
    ConfigLib.sortPaths(p);
    assertEq(p[0], "A.json");
    assertEq(p[1], "b.json");
  }

  function test_duplicatesArePreserved() public pure {
    string[] memory p = _paths("a.json", "b.json", "a.json");
    ConfigLib.sortPaths(p);
    _assertOrder(p, "a.json", "a.json", "b.json");
  }

  function test_emptyAndSingle_doNotRevert() public pure {
    string[] memory empty = new string[](0);
    ConfigLib.sortPaths(empty);
    assertEq(empty.length, 0);

    string[] memory one = new string[](1);
    one[0] = "only.json";
    ConfigLib.sortPaths(one);
    assertEq(one[0], "only.json");
  }

  function _paths(
    string memory a,
    string memory b
  ) internal pure returns (string[] memory p) {
    p = new string[](2);
    p[0] = a;
    p[1] = b;
  }

  function _paths(
    string memory a,
    string memory b,
    string memory c
  ) internal pure returns (string[] memory p) {
    p = new string[](3);
    p[0] = a;
    p[1] = b;
    p[2] = c;
  }

  function _assertOrder(
    string[] memory p,
    string memory a,
    string memory b,
    string memory c
  ) internal pure {
    assertEq(p.length, 3, "length");
    assertEq(p[0], a, "index 0");
    assertEq(p[1], b, "index 1");
    assertEq(p[2], c, "index 2");
  }
}
