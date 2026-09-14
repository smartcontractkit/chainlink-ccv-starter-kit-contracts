// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title AddressSetLib
/// @notice Set operations over memory address arrays, for reconciling a declared full
///         set against an on-chain EnumerableSet whose update API is add/remove deltas.
library AddressSetLib {
  function contains(
    address[] memory set,
    address needle
  ) internal pure returns (bool) {
    for (uint256 i = 0; i < set.length; ++i) {
      if (set[i] == needle) return true;
    }
    return false;
  }

  /// @notice Elements of `from` that are not in `exclude` (both treated as sets).
  function difference(
    address[] memory from,
    address[] memory exclude
  ) internal pure returns (address[] memory out) {
    address[] memory scratch = new address[](from.length);
    uint256 n = 0;
    for (uint256 i = 0; i < from.length; ++i) {
      if (!contains(exclude, from[i])) scratch[n++] = from[i];
    }
    out = new address[](n);
    for (uint256 i = 0; i < n; ++i) {
      out[i] = scratch[i];
    }
  }

  /// @notice Delta that turns `current` into `desired`: what to remove and what to add.
  ///         Both empty when the two already agree as sets.
  function diff(
    address[] memory current,
    address[] memory desired
  ) internal pure returns (address[] memory removes, address[] memory adds) {
    removes = difference(current, desired);
    adds = difference(desired, current);
  }

  /// @notice True when the two arrays hold the same set, ignoring order.
  function sameSet(
    address[] memory a,
    address[] memory b
  ) internal pure returns (bool) {
    return difference(a, b).length == 0 && difference(b, a).length == 0;
  }
}
