// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FinalityConfigLib} from "../../src/lib/FinalityConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The typed `allowedFinality` block against the FinalityCodec bytes4 it must
///         produce. Expected values come from the codec, so the test cannot drift from it.
contract FinalityConfigLibTest is Test {
  bytes4 internal constant FULL_FINALITY = FinalityCodec.WAIT_FOR_FINALITY_FLAG;
  bytes4 internal constant WAIT_FOR_SAFE = FinalityCodec.WAIT_FOR_SAFE_FLAG;
  bytes4 internal constant MAX_DEPTH = FinalityCodec.BLOCK_DEPTH_MASK;
  bytes4 internal constant DEPTH_1 = bytes4(uint32(1));
  bytes4 internal constant DEPTH_5 = bytes4(uint32(5));
  bytes4 internal constant SAFE_OR_DEPTH_5 = WAIT_FOR_SAFE | DEPTH_5;

  function _block(
    bool allowSafeTag,
    uint16 minBlockDepth
  ) internal pure returns (Types.AllowedFinality memory) {
    return Types.AllowedFinality({allowSafeTag: allowSafeTag, minBlockDepth: minBlockDepth});
  }

  // --------------------------------------------------------------------------
  //  encode: the four documented shapes
  // --------------------------------------------------------------------------
  function test_encode_emptyBlock_isFullFinalityOnly() public pure {
    assertEq(FinalityConfigLib.encode(_block(false, 0)), FULL_FINALITY);
  }

  function test_encode_safeTagOnly() public pure {
    assertEq(FinalityConfigLib.encode(_block(true, 0)), WAIT_FOR_SAFE);
  }

  function test_encode_depthOnly() public pure {
    assertEq(FinalityConfigLib.encode(_block(false, 5)), DEPTH_5);
    assertEq(FinalityConfigLib.encode(_block(false, 1)), DEPTH_1);
    assertEq(FinalityConfigLib.encode(_block(false, FinalityCodec.MAX_BLOCK_DEPTH)), MAX_DEPTH);
  }

  /// @dev The combined form is the codec's own `_encodeBlockDepthAndSafeFlag`, valid for
  ///      allowed finality: the two are alternatives a sender may pick from.
  function test_encode_safeTagOrDepth_matchesCodecEncoder() public pure {
    assertEq(FinalityConfigLib.encode(_block(true, 5)), SAFE_OR_DEPTH_5);
    assertEq(FinalityConfigLib.encode(_block(true, 5)), FinalityCodec._encodeBlockDepthAndSafeFlag(5));
  }

  /// @dev The point of the typed form: no input reaches bits 17-31.
  function testFuzz_encode_neverSetsReservedBits(
    bool allowSafeTag,
    uint16 minBlockDepth
  ) public pure {
    bytes4 encoded = FinalityConfigLib.encode(_block(allowSafeTag, minBlockDepth));
    assertFalse(FinalityConfigLib.hasReservedBits(encoded), "reserved bits unreachable from config");
    assertEq(encoded & FinalityCodec.BLOCK_DEPTH_MASK, bytes4(uint32(minBlockDepth)), "depth in the low 16 bits");
    assertEq(encoded & WAIT_FOR_SAFE != bytes4(0), allowSafeTag, "safe flag is bit 16");
  }

  /// @dev What the encoded cap actually admits, checked through the codec's own rule.
  function test_encode_safeTagOrDepth_admitsEitherRequestAlone() public pure {
    bytes4 allowed = FinalityConfigLib.encode(_block(true, 5));
    FinalityCodec._ensureRequestedFinalityAllowed(FULL_FINALITY, allowed);
    FinalityCodec._ensureRequestedFinalityAllowed(WAIT_FOR_SAFE, allowed);
    FinalityCodec._ensureRequestedFinalityAllowed(DEPTH_5, allowed);
    FinalityCodec._ensureRequestedFinalityAllowed(bytes4(uint32(9)), allowed);
  }

  function test_encode_depthIsAFloor() public {
    bytes4 allowed = FinalityConfigLib.encode(_block(false, 5));
    vm.expectRevert(abi.encodeWithSelector(FinalityCodec.InvalidRequestedFinality.selector, bytes4(uint32(4)), allowed));
    this.ensureAllowed(bytes4(uint32(4)), allowed);
  }

  function test_encode_emptyBlock_rejectsEveryFastPath() public {
    bytes4 allowed = FinalityConfigLib.encode(_block(false, 0));
    vm.expectRevert(abi.encodeWithSelector(FinalityCodec.InvalidRequestedFinality.selector, WAIT_FOR_SAFE, allowed));
    this.ensureAllowed(WAIT_FOR_SAFE, allowed);
    vm.expectRevert(abi.encodeWithSelector(FinalityCodec.InvalidRequestedFinality.selector, MAX_DEPTH, allowed));
    this.ensureAllowed(MAX_DEPTH, allowed);
  }

  /// @dev External wrapper so the codec's revert happens in a CALL, where expectRevert sees it.
  function ensureAllowed(
    bytes4 requested,
    bytes4 allowed
  ) external pure {
    FinalityCodec._ensureRequestedFinalityAllowed(requested, allowed);
  }

  // --------------------------------------------------------------------------
  //  decode / describe: reading an on-chain value back
  // --------------------------------------------------------------------------
  function testFuzz_decode_roundTripsEveryEncodedBlock(
    bool allowSafeTag,
    uint16 minBlockDepth
  ) public pure {
    Types.AllowedFinality memory back =
      FinalityConfigLib.decode(FinalityConfigLib.encode(_block(allowSafeTag, minBlockDepth)));
    assertEq(back.allowSafeTag, allowSafeTag);
    assertEq(back.minBlockDepth, minBlockDepth);
  }

  function test_decode_dropsReservedBits() public pure {
    Types.AllowedFinality memory back = FinalityConfigLib.decode(bytes4(0xDEAC0005));
    assertFalse(back.allowSafeTag);
    assertEq(back.minBlockDepth, 5);
    assertTrue(FinalityConfigLib.hasReservedBits(bytes4(0xDEAC0005)));
    assertFalse(FinalityConfigLib.hasReservedBits(bytes4(0x0001FFFF)));
  }

  function test_describe_namesWhatASenderMayRequest() public pure {
    assertEq(FinalityConfigLib.describe(FULL_FINALITY), "full finality only");
    assertEq(FinalityConfigLib.describe(WAIT_FOR_SAFE), "full finality, or safe tag");
    assertEq(FinalityConfigLib.describe(DEPTH_5), "full finality, or depth >= 5");
    assertEq(FinalityConfigLib.describe(SAFE_OR_DEPTH_5), "full finality, or safe tag, or depth >= 5");
    assertEq(FinalityConfigLib.describe(bytes4(0x00020000)), "full finality only (reserved bits set)");
  }
}
