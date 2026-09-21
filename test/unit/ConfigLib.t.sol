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
  string internal constant LANE_EXAMPLE = "config/operator/lanes/sepolia-to-base_sepolia.example.json";

  function test_readLaneByPath_parsesExample() public view {
    Types.LaneConfig memory lane = ConfigLib.readLaneByPath(LANE_EXAMPLE);

    assertEq(lane.name, "sepolia-to-base_sepolia");
    assertEq(lane.source.aliasName, "sepolia");
    assertEq(lane.source.chainSelector, 16015286601757825753);
    assertEq(lane.dest.aliasName, "base_sepolia");
    assertEq(lane.dest.chainSelector, 10344971235874465080);
    assertEq(lane.versionTag, bytes4(0x00010001), "mandatory versionTag parsed");
  }

  /// @dev The join the loader makes on a lane's behalf: the lane pins a tag, and the
  ///      committee for it comes from the SOURCE chain's operator file. Nothing about the
  ///      signer set is readable from the lane file, which is what stops two
  ///      destinations of one source from disagreeing.
  function test_committeeForExampleLane_comesFromTheSourceOperatorFile() public view {
    Types.LaneConfig memory lane = ConfigLib.readLaneByPath(LANE_EXAMPLE);
    assertEq(lane.source.aliasName, "sepolia", "the example operator file is this lane's source");

    Types.SignatureConfig memory committee =
    ConfigLib.verifierConfigByTag(ConfigLib.readOperatorByPath(ROLES_EXAMPLE), lane.versionTag).signatureConfig;

    assertEq(committee.threshold, 7, "threshold read from the source's operator file");
    assertEq(committee.signers.length, 10, "committee read from the source's operator file");
  }

  /// @dev One entry per verifier tag, carrying everything that verifier is declared
  ///      with. The committee must respect "threshold < signers, threshold > 2/3".
  function test_readOperatorByPath_parsesVerifierEntry() public view {
    Types.OperatorConfig memory operator = ConfigLib.readOperatorByPath(ROLES_EXAMPLE);
    assertEq(operator.verifiers.length, 1, "one entry per verifier tag");

    Types.VerifierConfig memory v = ConfigLib.verifierConfigByTag(operator, bytes4(0x00010001));
    assertEq(v.storageLocations.length, 1, "where this verifier's signers publish");
    assertFalse(v.allowedFinality.allowSafeTag, "example allows full finality only");
    assertEq(v.signatureConfig.threshold, 7);
    assertEq(v.signatureConfig.signers.length, 10);
    assertLt(v.signatureConfig.threshold, v.signatureConfig.signers.length); // not N-of-N
    assertGt(uint256(v.signatureConfig.threshold) * 3, v.signatureConfig.signers.length * 2); // > 2/3
    assertEq(v.roles.owner, address(0x2000000000000000000000000000000000000001), "role holders travel with it");
  }

  function test_verifierConfigByTag_revertsOnUndeclaredTag() public {
    Types.OperatorConfig memory operator = ConfigLib.readOperatorByPath(ROLES_EXAMPLE);
    try this.callVerifierConfigByTag(operator, 0x00010002) {
      fail();
    } catch Error(string memory reason) {
      assertTrue(vm.contains(reason, "no verifiers entry for versionTag 0x00010002"), reason);
    }
  }

  /// @dev External wrapper: library internals inline, and the revert must happen in a CALL.
  function callVerifierConfigByTag(
    Types.OperatorConfig memory operator,
    bytes4 tag
  ) external pure returns (Types.VerifierConfig memory) {
    return ConfigLib.verifierConfigByTag(operator, tag);
  }

  /// @dev The versionTag is mandatory: a lane without one must fail with a message that
  ///      shows the expected key, not a bare "key not found".
  function test_readLaneByPath_revertsWhenVersionTagMissing() public {
    _expectLaneRevert("missing-tag", _laneJsonWithVersionTagLine(""), "has no versionTag");
  }

  function test_readLaneByPath_revertsOnZeroVersionTag() public {
    _expectLaneRevert("zero-tag", _laneJsonWithVersionTagLine("\"versionTag\": \"0x00000000\","), "is malformed");
  }

  /// @dev Tags are cross-chain identities, so lanes may only pin tags enumerated in the
  ///      repo-wide catalog — a typo here would otherwise name a verifier that exists nowhere.
  function test_readLaneByPath_revertsOnUncatalogedVersionTag() public {
    _expectLaneRevert(
      "unknown-tag", _laneJsonWithVersionTagLine("\"versionTag\": \"0xdeadbeef\","), "not catalogued in"
    );
  }

  function test_readVersionTags_parsesTheCommittedCatalog() public view {
    bytes4[] memory tags = ConfigLib.readVersionTags();
    bool found = false;
    for (uint256 i = 0; i < tags.length; ++i) {
      if (tags[i] == bytes4(0x00010001)) found = true;
    }
    assertTrue(found, "the current versionTag is catalogued");
  }

  function test_requireKnownTag_acceptsCataloguedTag() public view {
    ConfigLib.requireKnownTag(bytes4(0x00010001), "test");
  }

  function test_requireKnownTag_revertsOnUnknownTag() public {
    try this.callRequireKnownTag(0xdeadbeef) {
      fail();
    } catch Error(string memory reason) {
      assertTrue(vm.contains(reason, "not catalogued in config/operator.json"), reason);
    }
  }

  /// @dev External wrapper: library internals inline, and the revert must happen in a CALL.
  function callRequireKnownTag(
    bytes4 tag
  ) external view {
    ConfigLib.requireKnownTag(tag, "test");
  }

  function _laneJsonWithVersionTagLine(
    string memory versionTagLine
  ) private pure returns (string memory) {
    return string.concat(
      '{"name":"tmp-lane",',
      '"source":{"alias":"a","chainSelector":"1"},',
      '"dest":{"alias":"b","chainSelector":"2"},',
      versionTagLine,
      '"allowlist":{"allowlistEnabled":false,"allowedSenders":[]}}'
    );
  }

  /// @dev Forge runs tests concurrently against a shared filesystem, so each test
  ///      writing a fixture file must use its OWN path.
  function _expectLaneRevert(
    string memory caseName,
    string memory json,
    string memory reasonFragment
  ) private {
    string memory path = string.concat("out/governance/lane-", caseName, ".local.json");
    vm.createDir("out/governance", true);
    vm.writeFile(path, json);
    try this.callReadLane(path) {
      fail();
    } catch Error(string memory reason) {
      assertTrue(vm.contains(reason, reasonFragment), string.concat("reason names the problem: ", reason));
    }
    vm.removeFile(path);
  }

  /// @dev External wrapper: library internals inline, and the revert must happen in a CALL.
  function callReadLane(
    string calldata path
  ) external view returns (Types.LaneConfig memory) {
    return ConfigLib.readLaneByPath(path);
  }

  function test_listLanes_skipsTemplatesAndExamples() public view {
    // Every listed path must be a .json and must NOT be a template or example,
    // regardless of how many real lane files exist locally.
    string[] memory lanes = ConfigLib.listLanes();
    for (uint256 i = 0; i < lanes.length; ++i) {
      assertTrue(_endsWithJson(lanes[i]), "listed path must end in .json");
      assertFalse(_contains(lanes[i], "_template"), "must skip _template files");
      assertFalse(_contains(lanes[i], ".example."), "must skip .example files");
    }
  }

  // ---------------------------------------------------------------------------
  //  roles: factory.allowlist
  // ---------------------------------------------------------------------------

  string internal constant ROLES_EXAMPLE = "config/operator/chains/sepolia.example.json";

  function test_readOperatorByPath_parsesFactoryAllowlist() public view {
    Types.OperatorConfig memory operator = ConfigLib.readOperatorByPath(ROLES_EXAMPLE);
    assertEq(operator.factory.roles.allowlist.length, 1, "one allowlisted account");
    assertEq(
      operator.factory.roles.allowlist[0], address(0x2000000000000000000000000000000000000001), "the example account"
    );
  }

  function test_readOperatorByPath_revertsWhenFactoryAllowlistMissing() public {
    _expectRolesRevert(
      "no-allowlist", _rolesJson('"factory":{"roles":{"owner":"0x2000000000000000000000000000000000000001"}}')
    );
  }

  function test_readOperatorByPath_revertsOnZeroInFactoryAllowlist() public {
    _expectRolesRevert(
      "zero-in-allowlist",
      _rolesJson(
        '"factory":{"roles":{"owner":"0x2000000000000000000000000000000000000001",'
        '"allowlist":["0x0000000000000000000000000000000000000000"]}}'
      ),
      "zero address in factory.allowlist"
    );
  }

  function test_readOperatorByPath_acceptsEmptyFactoryAllowlist() public {
    string memory path = "out/governance/roles-empty-allowlist.local.json";
    vm.createDir("out/governance", true);
    vm.writeFile(
      path, _rolesJson('"factory":{"roles":{"owner":"0x2000000000000000000000000000000000000001","allowlist":[]}}')
    );
    Types.OperatorConfig memory operator = ConfigLib.readOperatorByPath(path);
    assertEq(operator.factory.roles.allowlist.length, 0, "[] is the deliberate revoke-everyone set");
    vm.removeFile(path);
  }

  /// @dev An operator file with no verifiers, so only the `factory` object varies per case.
  function _rolesJson(
    string memory factoryObject
  ) private pure returns (string memory) {
    return string.concat(
      '{"alias":"zz-roles-fixture","verifiers":[],',
      '"resolver":{"roles":{"owner":"0x2000000000000000000000000000000000000001",',
      '"feeAggregator":"0x2000000000000000000000000000000000000005"}},',
      factoryObject,
      "}"
    );
  }

  function _expectRolesRevert(
    string memory caseName,
    string memory json
  ) private {
    _expectRolesRevert(caseName, json, "");
  }

  /// @dev Own fixture path per case: forge runs tests concurrently on a shared filesystem.
  ///      An empty `reasonFragment` asserts only that the file is rejected — a missing key
  ///      reverts inside the cheatcode, so its message is not ours to pin down.
  function _expectRolesRevert(
    string memory caseName,
    string memory json,
    string memory reasonFragment
  ) private {
    string memory path = string.concat("out/governance/roles-", caseName, ".local.json");
    vm.createDir("out/governance", true);
    vm.writeFile(path, json);
    bool reverted = true;
    try this.callReadRoles(path) {
      reverted = false;
    } catch Error(string memory reason) {
      if (bytes(reasonFragment).length > 0) {
        assertTrue(vm.contains(reason, reasonFragment), string.concat("reason names the problem: ", reason));
      }
    } catch {}
    vm.removeFile(path);
    assertTrue(reverted, "readOperatorByPath must reject this file");
  }

  /// @dev External wrapper: library internals inline, and the revert must happen in a CALL.
  function callReadRoles(
    string calldata path
  ) external view returns (Types.OperatorConfig memory) {
    return ConfigLib.readOperatorByPath(path);
  }

  // ---------------------------------------------------------------------------
  //  allowedFinality: the typed block (config/operator/chains)
  // ---------------------------------------------------------------------------
  function test_readOperatorByPath_parsesAllowedFinalityBlock() public {
    Types.OperatorConfig memory operator =
      _readOperator("finality-both", '"allowedFinality":{"allowSafeTag":true,"minBlockDepth":5},');
    assertTrue(operator.verifiers[0].allowedFinality.allowSafeTag, "safe tag read");
    assertEq(operator.verifiers[0].allowedFinality.minBlockDepth, 5, "depth read");
    assertEq(operator.verifiers[0].storageLocations.length, 1, "storage locations read");

    operator = _readOperator("finality-empty", '"allowedFinality":{},');
    assertFalse(operator.verifiers[0].allowedFinality.allowSafeTag, "empty block: no safe tag");
    assertEq(operator.verifiers[0].allowedFinality.minBlockDepth, 0, "empty block: no depth");

    operator = _readOperator("finality-max", '"allowedFinality":{"minBlockDepth":65535},');
    assertEq(operator.verifiers[0].allowedFinality.minBlockDepth, 65535, "max depth read");
  }

  function test_readOperatorByPath_revertsWhenAllowedFinalityMissing() public {
    _expectOperatorRevert("finality-missing", "", "has no .verifiers[0].allowedFinality");
  }

  /// @dev A misspelt key would otherwise load as full finality only, with no error.
  function test_readOperatorByPath_revertsOnUnknownAllowedFinalityKey() public {
    _expectOperatorRevert("finality-typo", '"allowedFinality":{"minBlockDepht":5},', "unknown key 'minBlockDepht'");
  }

  /// @dev Zero depth is the codec's spelling of full finality, so a written zero is a
  ///      contradiction; above 65535 does not fit the 16-bit field.
  function test_readOperatorByPath_revertsOnOutOfRangeMinBlockDepth() public {
    _expectOperatorRevert("finality-zero", '"allowedFinality":{"minBlockDepth":0},', "must be 1..65535");
    _expectOperatorRevert("finality-over", '"allowedFinality":{"minBlockDepth":65536},', "must be 1..65535");
  }

  function _operatorJson(
    string memory allowedFinalityLine
  ) private pure returns (string memory) {
    return string.concat(
      '{"alias":"tmp-operator","verifiers":[{"versionTag":"0x00010001",',
      allowedFinalityLine,
      '"storageLocations":["https://aggregator.example/ccv"],',
      '"signatureConfig":{"threshold":0,"signers":[]},',
      '"roles":{"owner":"0x2000000000000000000000000000000000000001",',
      '"storageLocationsAdmin":"0x2000000000000000000000000000000000000002",',
      '"allowlistAdmin":"0x2000000000000000000000000000000000000003",',
      '"feeAggregator":"0x2000000000000000000000000000000000000004"}}],',
      '"resolver":{"roles":{"owner":"0x2000000000000000000000000000000000000001",',
      '"feeAggregator":"0x2000000000000000000000000000000000000005"}},',
      '"factory":{"roles":{"owner":"0x2000000000000000000000000000000000000001","allowlist":[]}}}'
    );
  }

  /// @dev Own fixture path per case: forge runs tests concurrently on a shared filesystem.
  function _readOperator(
    string memory caseName,
    string memory allowedFinalityLine
  ) private returns (Types.OperatorConfig memory operator) {
    string memory path = string.concat("out/governance/operator-", caseName, ".local.json");
    vm.createDir("out/governance", true);
    vm.writeFile(path, _operatorJson(allowedFinalityLine));
    operator = ConfigLib.readOperatorByPath(path);
    vm.removeFile(path);
  }

  function _expectOperatorRevert(
    string memory caseName,
    string memory allowedFinalityLine,
    string memory reasonFragment
  ) private {
    string memory path = string.concat("out/governance/operator-", caseName, ".local.json");
    vm.createDir("out/governance", true);
    vm.writeFile(path, _operatorJson(allowedFinalityLine));
    try this.callReadRoles(path) {
      fail();
    } catch Error(string memory reason) {
      assertTrue(vm.contains(reason, reasonFragment), string.concat("reason names the problem: ", reason));
    }
    vm.removeFile(path);
  }

  // ---------------------------------------------------------------------------
  //  chains: the synced reference has a closed key set
  // ---------------------------------------------------------------------------
  function test_readChainByPath_parsesEveryKey() public {
    Types.ChainConfig memory chainConfig = _readChain("all-keys", "");
    assertEq(chainConfig.aliasName, "tmp-chain", "alias");
    assertEq(chainConfig.chainId, 31337, "chainId");
    assertEq(chainConfig.chainSelector, 1, "chainSelector");
    assertEq(chainConfig.router, address(1), "router");
    assertEq(chainConfig.rmn, address(1), "rmn");
    assertEq(chainConfig.feeTokens.length, 0, "feeTokens");
  }

  /// @dev A key the sync does not own is operator data in the wrong file.
  function test_readChainByPath_rejectsUnknownKey() public {
    _expectChainRevert("stray-key", '"stray":1,', "unknown key 'stray'");
  }

  function _chainJson(
    string memory extraLine
  ) private pure returns (string memory) {
    return string.concat(
      '{"alias":"tmp-chain","chainId":31337,"chainSelector":"1",',
      '"router":"0x0000000000000000000000000000000000000001",',
      '"rmn":"0x0000000000000000000000000000000000000001",',
      extraLine,
      '"feeTokens":[],"explorerAddressPath":""}'
    );
  }

  /// @dev Own fixture path per case: forge runs tests concurrently on a shared filesystem.
  function _readChain(
    string memory caseName,
    string memory extraLine
  ) private returns (Types.ChainConfig memory chainConfig) {
    string memory path = string.concat("out/governance/chain-", caseName, ".local.json");
    vm.createDir("out/governance", true);
    vm.writeFile(path, _chainJson(extraLine));
    chainConfig = ConfigLib.readChainByPath(path);
    vm.removeFile(path);
  }

  function _expectChainRevert(
    string memory caseName,
    string memory extraLine,
    string memory reasonFragment
  ) private {
    string memory path = string.concat("out/governance/chain-", caseName, ".local.json");
    vm.createDir("out/governance", true);
    vm.writeFile(path, _chainJson(extraLine));
    try this.callReadChain(path) {
      fail();
    } catch Error(string memory reason) {
      assertTrue(vm.contains(reason, reasonFragment), string.concat("reason names the problem: ", reason));
    }
    vm.removeFile(path);
  }

  // ---------------------------------------------------------------------------
  //  resolverSalt: the repo-wide operator file
  // ---------------------------------------------------------------------------
  function test_readResolverSaltByPath_readsTheSalt() public {
    string memory path = "out/governance/operator-salt-ok.local.json";
    vm.createDir("out/governance", true);
    vm.writeFile(
      path, '{"resolverSalt":"0x0000000000000000000000000000000000000000000000000000000000000001","versionTags":[]}'
    );
    assertEq(ConfigLib.readResolverSaltByPath(path), bytes32(uint256(1)), "salt read");
    vm.removeFile(path);
  }

  /// @dev A zero salt is the unfilled state; every unfilled fork would share an address.
  function test_readResolverSaltByPath_rejectsZero() public {
    string memory path = "out/governance/operator-salt-zero.local.json";
    vm.createDir("out/governance", true);
    vm.writeFile(
      path, '{"resolverSalt":"0x0000000000000000000000000000000000000000000000000000000000000000","versionTags":[]}'
    );
    try this.callReadResolverSalt(path) {
      fail();
    } catch Error(string memory reason) {
      assertTrue(vm.contains(reason, "resolverSalt in out/governance/operator-salt-zero.local.json is zero"), reason);
    }
    vm.removeFile(path);
  }

  /// @dev External wrapper: library internals inline, and the revert must happen in a CALL.
  function callReadResolverSalt(
    string calldata path
  ) external view returns (bytes32) {
    return ConfigLib.readResolverSaltByPath(path);
  }

  /// @dev External wrapper: library internals inline, and the revert must happen in a CALL.
  function callReadChain(
    string calldata path
  ) external view returns (Types.ChainConfig memory) {
    return ConfigLib.readChainByPath(path);
  }

  // ---------------------------------------------------------------------------
  //  chain-identity preflight (assertChain / assertChainMatches)
  // ---------------------------------------------------------------------------

  function test_assertChain_missingConfig_reverts() public {
    ChainAssertHarness h = new ChainAssertHarness();
    vm.expectRevert(bytes("ConfigLib: no chain config at config/chains/zz-no-such-chain.json"));
    h.assertChain("zz-no-such-chain");
  }

  /// @dev A file whose alias disagrees with its name is a config error, named as such.
  function test_assertChainMatches_aliasMismatch_reverts() public {
    ChainAssertHarness h = new ChainAssertHarness();
    try h.assertChainMatches(_chain("sepolia", 11155111), "base_sepolia") {
      fail();
    } catch Error(string memory reason) {
      assertTrue(vm.contains(reason, "declares alias 'sepolia'"), reason);
    }
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
