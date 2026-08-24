// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MockRMN
/// @notice Minimal stand-in for RMN. `BaseVerifier._assertNotCursedByRMN` only calls
///         `isCursed(bytes16)`.
/// @dev The fixture's placeholder RMN address has no code, and a staticcall to a codeless
///      address returns empty data that fails to decode as `bool`. Any test reaching
///      `forwardToVerifier` therefore needs a real contract here.
contract MockRMN {
  bool private s_cursed;

  function setCursed(
    bool cursed
  ) external {
    s_cursed = cursed;
  }

  function isCursed(
    bytes16
  ) external view returns (bool) {
    return s_cursed;
  }
}
