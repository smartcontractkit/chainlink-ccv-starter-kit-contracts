// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Types} from "./Types.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title FinalityConfigLib
/// @notice Converts the typed `allowedFinality` config block to and from the FinalityCodec
///         bytes4 the verifier stores.
/// @dev Allowed finality lists what a sender MAY request; the entries are alternatives.
///      `allowSafeTag` accepts a safe-tag request, `minBlockDepth` accepts a depth request
///      of at least that many blocks, and full finality is always accepted. That is the
///      rule `FinalityCodec._ensureRequestedFinalityAllowed` applies, so the field names
///      follow it rather than the bit layout.
library FinalityConfigLib {
  Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

  /// @dev Everything the codec does NOT assign: bits 17-31. Derived so the two assigned
  ///      fields stay the authority.
  bytes4 internal constant RESERVED_FLAGS_MASK = ~(FinalityCodec.WAIT_FOR_SAFE_FLAG | FinalityCodec.BLOCK_DEPTH_MASK);

  /// @notice The bytes4 for a typed block. A flag plus a 16-bit depth cannot reach the
  ///         reserved bits, so every encoded config value is well-formed by construction.
  function encode(
    Types.AllowedFinality memory finality
  ) internal pure returns (bytes4 encoded) {
    encoded = FinalityCodec._encodeBlockDepth(finality.minBlockDepth);
    if (finality.allowSafeTag) encoded |= FinalityCodec.WAIT_FOR_SAFE_FLAG;
  }

  /// @notice The two assigned fields of a bytes4. Reserved bits are dropped, so
  ///         `encode(decode(x)) == x` only when `hasReservedBits(x)` is false.
  function decode(
    bytes4 encoded
  ) internal pure returns (Types.AllowedFinality memory finality) {
    finality.allowSafeTag = encoded & FinalityCodec.WAIT_FOR_SAFE_FLAG != bytes4(0);
    // masking to the low 16 bits first makes the narrowing exact
    // forge-lint: disable-next-line(unsafe-typecast)
    finality.minBlockDepth = uint16(uint32(encoded & FinalityCodec.BLOCK_DEPTH_MASK));
  }

  /// @notice True when `encoded` sets a bit the codec assigns no meaning to. Config cannot
  ///         produce such a value; an on-chain one was set by other tooling.
  function hasReservedBits(
    bytes4 encoded
  ) internal pure returns (bool) {
    return encoded & RESERVED_FLAGS_MASK != bytes4(0);
  }

  /// @notice What a sender may request under `encoded`, in words, for logs and drift output.
  function describe(
    bytes4 encoded
  ) internal pure returns (string memory text) {
    Types.AllowedFinality memory finality = decode(encoded);
    text = "full finality";
    if (finality.allowSafeTag) text = string.concat(text, ", or safe tag");
    if (finality.minBlockDepth != 0) {
      text = string.concat(text, ", or depth >= ", vm.toString(uint256(finality.minBlockDepth)));
    }
    if (!finality.allowSafeTag && finality.minBlockDepth == 0) text = string.concat(text, " only");
    if (hasReservedBits(encoded)) text = string.concat(text, " (reserved bits set)");
  }
}
