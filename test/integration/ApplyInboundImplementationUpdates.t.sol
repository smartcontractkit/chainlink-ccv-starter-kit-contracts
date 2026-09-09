// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ApplyInboundImplementationUpdates} from "../../script/configure/ApplyInboundImplementationUpdates.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";

/// @dev Exposes the internal lane-derived tag set for direct testing.
contract ApplyInboundImplementationUpdatesHarness is ApplyInboundImplementationUpdates {
  function inboundTags(
    string[] memory lanePaths,
    string memory chainAlias
  ) external view returns (bytes4[] memory) {
    return _inboundTags(lanePaths, chainAlias);
  }

  function dedupedDestTags(
    Types.LaneConfig[] memory lanes,
    string memory chainAlias
  ) external pure returns (bytes4[] memory) {
    return _dedupedDestTags(lanes, chainAlias);
  }
}

/// @notice Exercises the ApplyInboundImplementationUpdates builder against the real
///         audited VersionedVerifierResolver (deployed by the fixture, owned by this test).
contract ApplyInboundImplementationUpdatesTest is CommitteeVerifierSetup {
  ApplyInboundImplementationUpdatesHarness internal script;

  bytes4 internal constant VERSION = 0x00010001;

  function setUp() public override {
    super.setUp();
    script = new ApplyInboundImplementationUpdatesHarness();
  }

  function _applyInbound(
    bytes4 version,
    address impl
  ) internal returns (bool ok) {
    BaseScript.Call memory call = script.callFor(address(resolver), script.toInboundArgs(version, impl));
    assertEq(call.to, address(resolver), "target is resolver");
    (ok,) = call.to.call(call.data); // msg.sender == owner (this test)
  }

  function _inboundImplementation(
    bytes4 version
  ) internal view returns (address) {
    return resolver.getInboundImplementation(abi.encodePacked(version));
  }

  function test_callFor_setsInboundImplementation() public {
    assertTrue(_applyInbound(VERSION, address(verifier)), "apply failed");
    assertEq(_inboundImplementation(VERSION), address(verifier), "version -> verifier mapping");
  }

  function test_zeroVerifier_clearsMapping() public {
    assertTrue(_applyInbound(VERSION, address(verifier)), "set failed");
    assertTrue(_applyInbound(VERSION, address(0)), "clear failed");
    assertEq(_inboundImplementation(VERSION), address(0), "mapping cleared");
  }

  function test_reverts_whenVersionZeroWithNonZeroVerifier() public {
    // version == 0 with a non-zero verifier -> InvalidVersion.
    assertFalse(_applyInbound(bytes4(0), address(verifier)), "should have reverted");
  }

  function test_reverts_whenCallerNotOwner() public {
    BaseScript.Call memory call = script.callFor(address(resolver), script.toInboundArgs(VERSION, address(verifier)));
    vm.prank(address(0xBAD));
    (bool ok,) = call.to.call(call.data); // onlyOwner
    assertFalse(ok, "non-owner should not update inbound implementations");
  }

  function test_toInboundArgs_translatesFields() public view {
    VersionedVerifierResolver.InboundImplementationArgs[] memory args = script.toInboundArgs(VERSION, address(verifier));
    assertEq(args.length, 1);
    assertEq(args[0].version, VERSION);
    assertEq(args[0].verifier, address(verifier));
  }

  // ---------------------------------------------------------------------------
  //  _inboundTags: the tag set derived from lanes whose DEST is this chain
  // ---------------------------------------------------------------------------

  /// @dev Forge runs tests concurrently against a shared filesystem, so these
  ///      fixture lanes use paths unique to this test contract.
  function _writeLaneFixture(
    string memory fileName,
    string memory sourceAlias,
    string memory destAlias,
    string memory versionTag
  ) private returns (string memory path) {
    path = string.concat("out/governance/inbound-tags-", fileName, ".local.json");
    vm.createDir("out/governance", true);
    vm.writeFile(
      path,
      string.concat(
        '{"name":"',
        sourceAlias,
        "-to-",
        destAlias,
        '",',
        '"source":{"alias":"',
        sourceAlias,
        '","chainSelector":"1"},',
        '"dest":{"alias":"',
        destAlias,
        '","chainSelector":"2"},',
        '"versionTag":"',
        versionTag,
        '",',
        '"signatureConfig":{"threshold":1,"signers":[]},',
        // Explicit router: an absent one inherits from chains/<source>.json, which
        // these synthetic aliases do not have.
        '"remoteChainConfig":{"router":"0x0000000000000000000000000000000000000001",',
        '"feeUSDCents":0,"gasForVerification":200000,"payloadSizeBytes":0},',
        '"allowlist":{"allowlistEnabled":false,"addedAllowlistedSenders":[],"removedAllowlistedSenders":[]}}'
      )
    );
  }

  function _lane(
    string memory sourceAlias,
    string memory destAlias,
    bytes4 versionTag
  ) private pure returns (Types.LaneConfig memory lane) {
    lane.source.aliasName = sourceAlias;
    lane.dest.aliasName = destAlias;
    lane.versionTag = versionTag;
  }

  /// @dev In-memory lanes: the selection logic is tag-agnostic, so this needs no
  ///      catalog entries beyond what the tags themselves assert.
  function test_dedupedDestTags_filtersByDestAndDeduplicates() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](4);
    lanes[0] = _lane("a", "x", 0x00010001);
    lanes[1] = _lane("b", "x", 0x00010001); // duplicate tag, same dest
    lanes[2] = _lane("c", "x", 0x00010002); // second tag, same dest
    lanes[3] = _lane("x", "d", 0x00010001); // x is SOURCE here: excluded

    bytes4[] memory tags = script.dedupedDestTags(lanes, "x");
    assertEq(tags.length, 2, "two unique tags serve lanes into x");
    assertEq(tags[0], bytes4(0x00010001), "first tag in lane order");
    assertEq(tags[1], bytes4(0x00010002), "second tag deduplicated in");

    bytes4[] memory destOnly = script.dedupedDestTags(lanes, "d");
    assertEq(destOnly.length, 1, "only the x->d lane targets d");
    assertEq(destOnly[0], bytes4(0x00010001));
  }

  function test_dedupedDestTags_emptyWhenNoLaneTargetsChain() public view {
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](1);
    lanes[0] = _lane("a", "b", 0x00010001);

    assertEq(script.dedupedDestTags(lanes, "elsewhere").length, 0, "no lane has this chain as destination");
  }

  /// @dev End-to-end through lane files. Only catalogued tags can appear in a real
  ///      lane file, so this sticks to the example catalog's tag; the multi-tag
  ///      dedup cases live on _dedupedDestTags above.
  function test_inboundTags_readsLaneFilesAndFiltersByDest() public {
    string[] memory lanePaths = new string[](2);
    lanePaths[0] = _writeLaneFixture("a-to-x", "a", "x", "0x00010001");
    lanePaths[1] = _writeLaneFixture("x-to-d", "x", "d", "0x00010001");

    bytes4[] memory tags = script.inboundTags(lanePaths, "x");
    assertEq(tags.length, 1, "one lane targets x");
    assertEq(tags[0], bytes4(0x00010001));
    assertEq(script.inboundTags(lanePaths, "elsewhere").length, 0, "no lane has this chain as destination");

    for (uint256 i = 0; i < lanePaths.length; ++i) {
      vm.removeFile(lanePaths[i]);
    }
  }
}
