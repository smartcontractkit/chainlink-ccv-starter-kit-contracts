// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// vm.serializeX accumulates into the object; only the final call returns the JSON.
// forge-lint: disable-start(unused-return)

import {Types} from "./Types.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title ConfigLib
/// @notice Loads config-as-data JSON from `config/` into typed structs.
/// @dev Fields are read one-by-one (rather than abi.decode of a whole object) so
///      the loader is robust to JSON key ordering and to fields being added later.
///      Chain selectors are stored as JSON strings and parsed here, because they
///      exceed the 2^53 safe-integer range of most JSON tooling.
library ConfigLib {
  Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

  string private constant CHAINS_DIR = "config/chains/";
  string private constant LANES_DIR = "config/lanes/";
  string private constant ROLES_DIR = "config/roles/";
  string private constant DEPLOYMENTS_DIR = "config/deployments/";
  string private constant VERSION_TAGS_PATH = "config/version-tags.json";

  string internal constant BARE_VERIFIER_TARGET_ERROR =
    "ConfigLib: target 'verifier' needs a versionTag - use verifier:<versionTag> (e.g. verifier:0x00010001)";

  // --------------------------------------------------------------------------
  //  version tags (the repo-wide catalog)
  // --------------------------------------------------------------------------
  /// @notice Every versionTag this repo uses, from config/version-tags.json. Tags are
  ///         CROSS-CHAIN identities (a lane's tag must match on both endpoints), so the
  ///         catalog is repo-wide, not per chain: one spelling everywhere.
  function readVersionTags() internal view returns (bytes4[] memory tags) {
    require(vm.exists(VERSION_TAGS_PATH), string.concat("ConfigLib: missing ", VERSION_TAGS_PATH));
    string memory json = vm.readFile(VERSION_TAGS_PATH);
    uint256 count = 0;
    while (vm.keyExistsJson(json, string.concat(".versionTags[", vm.toString(count), "]"))) {
      ++count;
    }
    tags = new bytes4[](count);
    for (uint256 i = 0; i < count; ++i) {
      bytes4 tag = _parseVersionTag(json, string.concat(".versionTags[", vm.toString(i), "].tag"), VERSION_TAGS_PATH);
      for (uint256 j = 0; j < i; ++j) {
        require(
          tags[j] != tag, string.concat("ConfigLib: duplicate versionTag ", tagToString(tag), " in ", VERSION_TAGS_PATH)
        );
      }
      tags[i] = tag;
    }
  }

  /// @dev Parses a versionTag field and enforces the documented scheme: 2 bytes operator
  ///      id + 2 bytes version, both halves non-zero. The scheme lives here (not in
  ///      `_parseBytes4`) because other bytes4 fields have different rules —
  ///      finalityConfig 0x00000000 is the legitimate production default.
  function _parseVersionTag(
    string memory json,
    string memory key,
    string memory source
  ) private pure returns (bytes4 tag) {
    tag = _parseBytes4(json, key);
    // truncating to 'bytes2' is deliberate: each half of the tag is inspected separately
    // forge-lint: disable-next-item(unsafe-typecast)
    bool wellFormed = bytes2(tag) != bytes2(0) && bytes2(tag << 16) != bytes2(0);
    require(
      wellFormed,
      string.concat(
        "ConfigLib: versionTag ",
        tagToString(tag),
        " in ",
        source,
        " is malformed - scheme is 2-byte operator id + 2-byte version, both non-zero"
      )
    );
  }

  /// @notice Reverts unless `tag` is catalogued. Applied where a HUMAN introduces a tag
  ///         (the DeployVerifier argument, lane files); machine-written records are
  ///         cross-checked against the chain by DriftCheck instead.
  function requireKnownTag(
    bytes4 tag,
    string memory context
  ) internal view {
    bytes4[] memory tags = readVersionTags();
    for (uint256 i = 0; i < tags.length; ++i) {
      if (tags[i] == tag) return;
    }
    revert(
      string.concat(
        "ConfigLib: versionTag ",
        tagToString(tag),
        " (",
        context,
        ") is not catalogued in ",
        VERSION_TAGS_PATH,
        " - add it there first"
      )
    );
  }

  // --------------------------------------------------------------------------
  //  chains
  // --------------------------------------------------------------------------
  function chainPath(
    string memory aliasName
  ) internal pure returns (string memory) {
    return string.concat(CHAINS_DIR, aliasName, ".json");
  }

  function readChain(
    string memory aliasName
  ) internal view returns (Types.ChainConfig memory) {
    return readChainByPath(chainPath(aliasName));
  }

  /// @notice Chain config if the file exists, else an empty struct (`chainId == 0`).
  /// @dev For callers that must tolerate an alias with no chain file, e.g. a test scope.
  function readChainOrEmpty(
    string memory aliasName
  ) internal view returns (Types.ChainConfig memory chainConfig) {
    string memory path = chainPath(aliasName);
    if (vm.exists(path)) return readChainByPath(path);
  }

  function readChainByPath(
    string memory path
  ) internal view returns (Types.ChainConfig memory chainConfig) {
    string memory json = vm.readFile(path);
    chainConfig.aliasName = vm.parseJsonString(json, ".alias");
    chainConfig.chainId = vm.parseJsonUint(json, ".chainId");
    chainConfig.chainSelector = _toUint64(vm.parseUint(vm.parseJsonString(json, ".chainSelector")), ".chainSelector");
    chainConfig.rmn = vm.parseJsonAddress(json, ".rmn");
    // Optional while older configs predate the field; the sync tooling maintains it.
    chainConfig.router = vm.keyExistsJson(json, ".router") ? vm.parseJsonAddress(json, ".router") : address(0);
    chainConfig.finalityConfig = _parseBytes4(json, ".finalityConfig");
    chainConfig.storageLocations = vm.parseJsonStringArray(json, ".storageLocations");
    // Optional by design: fee sweeping is opt-in per chain, and the token list mirrors a
    // Chainlink-governed set (see config/README.md). A chain whose list is not decided yet
    // must still load for every other script, so absent => empty => fee scripts no-op.
    chainConfig.feeTokens =
      vm.keyExistsJson(json, ".feeTokens") ? vm.parseJsonAddressArray(json, ".feeTokens") : new address[](0);
    chainConfig.resolverSalt = vm.parseJsonBytes32(json, ".resolverSalt");
  }

  /// @notice Fail-fast chain-identity preflight: the named chain config must exist,
  ///         name itself consistently, and — when an RPC backs the run — match the
  ///         connected network. Call before deployment lookup, reads, or staging.
  /// @dev A valid config against the wrong RPC can pass every other check, so only the
  ///      connected network's own chainid settles which chain a run is acting on.
  function assertChain(
    string memory aliasName
  ) internal view {
    string memory path = chainPath(aliasName);
    require(vm.exists(path), string.concat("ConfigLib: no chain config at ", path));
    assertChainMatches(readChainByPath(path), aliasName);
  }

  /// @dev Split from assertChain for callers that already loaded the config (and tests).
  function assertChainMatches(
    Types.ChainConfig memory chainConfig,
    string memory aliasName
  ) internal view {
    require(
      _stringsEqual(chainConfig.aliasName, aliasName),
      string.concat("ConfigLib: ", chainPath(aliasName), " declares alias '", chainConfig.aliasName, "'")
    );
    require(chainConfig.chainId != 0, string.concat("ConfigLib: ", chainPath(aliasName), " has no chainId"));
    // Every script requires a live RPC (preflights and batch gating read chain state).
    // Without --rpc-url forge runs at 31337, so for a config expecting another chain an
    // unexpected 31337 almost always means the flag is missing — fail with that hint.
    // A config genuinely FOR 31337 (a local anvil chain) is compared like any other.
    require(
      block.chainid != 31337 || chainConfig.chainId == 31337,
      string.concat(
        "ConfigLib: chainid is 31337 but ",
        aliasName,
        " is chain ",
        vm.toString(chainConfig.chainId),
        " - no --rpc-url passed?"
      )
    );
    require(
      block.chainid == chainConfig.chainId,
      string.concat(
        "ConfigLib: connected to chain ",
        vm.toString(block.chainid),
        " but ",
        aliasName,
        " is chain ",
        vm.toString(chainConfig.chainId)
      )
    );
  }

  // --------------------------------------------------------------------------
  //  lanes
  // --------------------------------------------------------------------------
  function lanePath(
    string memory laneName
  ) internal pure returns (string memory) {
    return string.concat(LANES_DIR, laneName, ".json");
  }

  /// @notice Loads one lane by name.
  /// @dev The filename and the `name` field must agree. A mismatch is a config error, not
  ///      a lookup miss, so it fails with that reason rather than "no such lane".
  function readLane(
    string memory laneName
  ) internal view returns (Types.LaneConfig memory lane) {
    lane = readLaneByPath(lanePath(laneName));
    require(
      _stringsEqual(lane.name, laneName),
      string.concat("ConfigLib: ", lanePath(laneName), " declares name '", lane.name, "'")
    );
  }

  /// @notice Returns the file paths of every real lane config (skips `_template`
  ///         and `*.example.json`). Feed each path to `readLaneByPath`.
  /// @dev For callers that need "every lane touching chain X" — they filter on
  ///      `lane.source`/`lane.dest`. To fetch a single known lane, use `readLane`.
  /// @dev Sorted before returning. `vm.readDir` order is filesystem-dependent, and the
  ///      lane-iterating scripts stage every lane into ONE Safe batch, so unsorted paths
  ///      make the generated JSON byte-differ between machines and defeat batch diffing.
  function listLanes() internal view returns (string[] memory paths) {
    Vm.DirEntry[] memory entries = vm.readDir(LANES_DIR);
    string[] memory buf = new string[](entries.length);
    uint256 n = 0;
    for (uint256 i = 0; i < entries.length; ++i) {
      string memory p = entries[i].path;
      if (_hasSuffix(p, ".json") && !_contains(p, "_template") && !_contains(p, ".example.")) {
        buf[n++] = p;
      }
    }

    paths = new string[](n);
    for (uint256 i = 0; i < n; ++i) {
      paths[i] = buf[i];
    }

    sortPaths(paths);
  }

  /// @notice Sorts byte-wise lexicographically, in place. Insertion sort: the input is a
  ///         directory listing, so n is small.
  function sortPaths(
    string[] memory paths
  ) internal pure {
    for (uint256 i = 1; i < paths.length; ++i) {
      string memory key = paths[i];
      uint256 j = i;
      while (j > 0 && _stringLessThan(key, paths[j - 1])) {
        paths[j] = paths[j - 1];
        --j;
      }
      paths[j] = key;
    }
  }

  function readLaneByPath(
    string memory path
  ) internal view returns (Types.LaneConfig memory lane) {
    string memory json = vm.readFile(path);
    lane.name = vm.parseJsonString(json, ".name");

    lane.source.aliasName = vm.parseJsonString(json, ".source.alias");
    lane.source.chainSelector =
      _toUint64(vm.parseUint(vm.parseJsonString(json, ".source.chainSelector")), ".source.chainSelector");
    lane.dest.aliasName = vm.parseJsonString(json, ".dest.alias");
    lane.dest.chainSelector =
      _toUint64(vm.parseUint(vm.parseJsonString(json, ".dest.chainSelector")), ".dest.chainSelector");

    // Mandatory: the lane pins the verifier serving it (both legs — the
    // contract forces source tag == dest tag). No inheritance, no sole-verifier default.
    require(
      vm.keyExistsJson(json, ".versionTag"),
      string.concat("ConfigLib: lane ", lane.name, " has no versionTag - add \"versionTag\": \"0x00010001\" (bytes4)")
    );
    lane.versionTag = _parseVersionTag(json, ".versionTag", path);
    requireKnownTag(lane.versionTag, string.concat("lane ", lane.name));

    lane.signatureConfig.threshold =
      _toUint8(vm.parseJsonUint(json, ".signatureConfig.threshold"), ".signatureConfig.threshold");
    lane.signatureConfig.signers = vm.parseJsonAddressArray(json, ".signatureConfig.signers");

    // Optional override: absent inherits the SOURCE chain's synced router; an explicit
    // 0x0 pauses the lane. An inherited zero means the chain was never synced - error.
    if (vm.keyExistsJson(json, ".remoteChainConfig.router")) {
      lane.remote.router = vm.parseJsonAddress(json, ".remoteChainConfig.router");
    } else {
      lane.remote.router = readChain(lane.source.aliasName).router;
      require(
        lane.remote.router != address(0),
        string.concat(
          "ConfigLib: lane ",
          lane.name,
          " inherits its router, but chains/",
          lane.source.aliasName,
          ".json has none - run sync-ccip-config.sh sync ",
          lane.source.aliasName
        )
      );
    }
    lane.remote.feeUSDCents =
      _toUint16(vm.parseJsonUint(json, ".remoteChainConfig.feeUSDCents"), ".remoteChainConfig.feeUSDCents");
    lane.remote.gasForVerification = _toUint32(
      vm.parseJsonUint(json, ".remoteChainConfig.gasForVerification"), ".remoteChainConfig.gasForVerification"
    );
    lane.remote.payloadSizeBytes =
      _toUint16(vm.parseJsonUint(json, ".remoteChainConfig.payloadSizeBytes"), ".remoteChainConfig.payloadSizeBytes");

    lane.allowlist.allowlistEnabled = vm.parseJsonBool(json, ".allowlist.allowlistEnabled");
    lane.allowlist.added = vm.parseJsonAddressArray(json, ".allowlist.addedAllowlistedSenders");
    lane.allowlist.removed = vm.parseJsonAddressArray(json, ".allowlist.removedAllowlistedSenders");
  }

  // --------------------------------------------------------------------------
  //  roles
  // --------------------------------------------------------------------------
  function readRoles(
    string memory aliasName
  ) internal view returns (Types.RolesConfig memory) {
    return readRolesByPath(string.concat(ROLES_DIR, aliasName, ".json"));
  }

  /// @notice Read roles, or a zeroed struct if the file does not exist. Lets optional
  ///         steps (e.g. factory ownership handover) proceed without a roles file.
  function readRolesOrEmpty(
    string memory aliasName
  ) internal view returns (Types.RolesConfig memory roles) {
    string memory path = string.concat(ROLES_DIR, aliasName, ".json");
    if (vm.exists(path)) return readRolesByPath(path);
    roles.aliasName = aliasName;
  }

  function readRolesByPath(
    string memory path
  ) internal view returns (Types.RolesConfig memory roles) {
    string memory json = vm.readFile(path);
    roles.aliasName = vm.parseJsonString(json, ".alias");

    // Absent array == no verifiers declared yet (factory-only chains).
    uint256 count = 0;
    while (vm.keyExistsJson(json, _rolesEntryKey(count, ""))) {
      ++count;
    }
    roles.verifiers = new Types.VerifierRoles[](count);
    for (uint256 i = 0; i < count; ++i) {
      bytes4 tag = _parseVersionTag(json, _rolesEntryKey(i, ".versionTag"), path);
      for (uint256 j = 0; j < i; ++j) {
        require(
          roles.verifiers[j].versionTag != tag,
          string.concat("ConfigLib: duplicate versionTag ", tagToString(tag), " in ", path)
        );
      }
      roles.verifiers[i] = Types.VerifierRoles({
        versionTag: tag,
        owner: vm.parseJsonAddress(json, _rolesEntryKey(i, ".owner")),
        storageLocationsAdmin: vm.parseJsonAddress(json, _rolesEntryKey(i, ".storageLocationsAdmin")),
        allowlistAdmin: vm.parseJsonAddress(json, _rolesEntryKey(i, ".allowlistAdmin")),
        feeAggregator: vm.parseJsonAddress(json, _rolesEntryKey(i, ".feeAggregator"))
      });
    }

    roles.resolver.owner = vm.parseJsonAddress(json, ".resolver.owner");
    roles.resolver.feeAggregator = vm.parseJsonAddress(json, ".resolver.feeAggregator");
    roles.factoryOwner = vm.parseJsonAddress(json, ".factory.owner");
  }

  function _rolesEntryKey(
    uint256 index,
    string memory field
  ) private pure returns (string memory) {
    return string.concat(".verifiers[", vm.toString(index), "]", field);
  }

  /// @notice The role holders declared for `tag`. Reverts when that tag has no
  ///         entry — roles are intent and precede the deploy, so declare them first.
  function verifierRolesByTag(
    Types.RolesConfig memory roles,
    bytes4 tag
  ) internal pure returns (Types.VerifierRoles memory) {
    for (uint256 i = 0; i < roles.verifiers.length; ++i) {
      if (roles.verifiers[i].versionTag == tag) return roles.verifiers[i];
    }
    revert(
      string.concat(
        "ConfigLib: no verifier roles for versionTag ",
        tagToString(tag),
        " in config/roles/",
        roles.aliasName,
        ".json - declare that verifier's roles first"
      )
    );
  }

  function hasVerifierRolesTag(
    Types.RolesConfig memory roles,
    bytes4 tag
  ) internal pure returns (bool) {
    for (uint256 i = 0; i < roles.verifiers.length; ++i) {
      if (roles.verifiers[i].versionTag == tag) return true;
    }
    return false;
  }

  // --------------------------------------------------------------------------
  //  target resolution ("verifier:<versionTag>" | "resolver" | "factory")
  // --------------------------------------------------------------------------
  /// @notice Maps a target name to its address in the deployment record.
  /// @dev A verifier is always addressed by versionTag: `verifier:0x00010001`. A bare
  ///      `verifier` is rejected — several verifiers can be live at once, and nothing
  ///      may silently pick one.
  function targetAddress(
    Types.Deployment memory deployment,
    string memory target
  ) internal pure returns (address) {
    if (_stringsEqual(target, "verifier")) revert(BARE_VERIFIER_TARGET_ERROR);
    if (_hasPrefix(target, "verifier:")) return verifierByTag(deployment, _tagSuffix(target));
    if (_stringsEqual(target, "resolver")) return deployment.resolver;
    if (_stringsEqual(target, "factory")) return deployment.factory;
    revert(_unknownTarget(target));
  }

  /// @notice Maps a target name to the owner declared for it in `config/roles`.
  /// @dev Role holders are per verifier; `verifier:<tag>` selects that verifier's
  ///      owner (same grammar as `targetAddress`).
  function targetOwner(
    Types.RolesConfig memory roles,
    string memory target
  ) internal pure returns (address) {
    if (_stringsEqual(target, "verifier")) revert(BARE_VERIFIER_TARGET_ERROR);
    if (_hasPrefix(target, "verifier:")) return verifierRolesByTag(roles, _tagSuffix(target)).owner;
    if (_stringsEqual(target, "resolver")) return roles.resolver.owner;
    if (_stringsEqual(target, "factory")) return roles.factoryOwner;
    revert(_unknownTarget(target));
  }

  function _unknownTarget(
    string memory target
  ) private pure returns (string memory) {
    return string.concat("ConfigLib: unknown target '", target, "' (expected verifier:<versionTag>|resolver|factory)");
  }

  /// @dev Parses the bytes4 after "verifier:", e.g. "verifier:0x00010001".
  function _tagSuffix(
    string memory target
  ) private pure returns (bytes4) {
    bytes memory targetBytes = bytes(target);
    bytes memory suffix = new bytes(targetBytes.length - 9); // len("verifier:") == 9
    for (uint256 i = 0; i < suffix.length; ++i) {
      suffix[i] = targetBytes[i + 9];
    }
    bytes memory raw = vm.parseBytes(string(suffix));
    require(raw.length == 4, string.concat("ConfigLib: '", target, "' must carry a 4-byte hex versionTag"));
    return _toBytes4(raw);
  }

  function _stringsEqual(
    string memory left,
    string memory right
  ) private pure returns (bool) {
    return keccak256(bytes(left)) == keccak256(bytes(right));
  }

  // --------------------------------------------------------------------------
  //  deployments (recorded addresses; written by the deploy scripts)
  // --------------------------------------------------------------------------
  function deploymentPath(
    string memory aliasName
  ) internal pure returns (string memory) {
    return string.concat(DEPLOYMENTS_DIR, aliasName, ".json");
  }

  function readDeployment(
    string memory aliasName
  ) internal view returns (Types.Deployment memory) {
    return readDeploymentByPath(deploymentPath(aliasName));
  }

  function readDeploymentByPath(
    string memory path
  ) internal view returns (Types.Deployment memory deployment) {
    string memory json = vm.readFile(path);
    deployment.aliasName = vm.parseJsonString(json, ".alias");
    deployment.factory = vm.parseJsonAddress(json, ".factory");
    deployment.resolver = vm.parseJsonAddress(json, ".resolver");

    // Absent array == nothing deployed yet (records are written one contract at a time).
    uint256 count = 0;
    while (vm.keyExistsJson(json, _verifierEntryKey(count, ""))) {
      ++count;
    }
    deployment.verifiers = new Types.VerifierDeployment[](count);
    for (uint256 i = 0; i < count; ++i) {
      bytes4 tag = _parseVersionTag(json, _verifierEntryKey(i, ".versionTag"), path);
      address addr = vm.parseJsonAddress(json, _verifierEntryKey(i, ".address"));
      require(addr != address(0), string.concat("ConfigLib: zero verifier address in ", path));
      for (uint256 j = 0; j < i; ++j) {
        require(
          deployment.verifiers[j].versionTag != tag,
          string.concat("ConfigLib: duplicate versionTag ", tagToString(tag), " in ", path)
        );
      }
      deployment.verifiers[i] = Types.VerifierDeployment({versionTag: tag, addr: addr});
    }
  }

  function _verifierEntryKey(
    uint256 index,
    string memory field
  ) private pure returns (string memory) {
    return string.concat(".verifiers[", vm.toString(index), "]", field);
  }

  /// @notice The verifier deployed for `tag`. Reverts when that tag is not
  ///         recorded — deploy it first (DeployVerifier appends it to the record).
  function verifierByTag(
    Types.Deployment memory deployment,
    bytes4 tag
  ) internal pure returns (address) {
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      if (deployment.verifiers[i].versionTag == tag) return deployment.verifiers[i].addr;
    }
    revert(
      string.concat(
        "ConfigLib: no verifier with versionTag ",
        tagToString(tag),
        " recorded for ",
        deployment.aliasName,
        " - deploy that verifier first"
      )
    );
  }

  function hasVerifierTag(
    Types.Deployment memory deployment,
    bytes4 tag
  ) internal pure returns (bool) {
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      if (deployment.verifiers[i].versionTag == tag) return true;
    }
    return false;
  }

  /// @notice Read the deployment record, or a zeroed struct (with alias set) if the
  ///         file does not exist yet. Lets deploy scripts merge one address at a time.
  function readDeploymentOrEmpty(
    string memory aliasName
  ) internal view returns (Types.Deployment memory deployment) {
    string memory path = deploymentPath(aliasName);
    if (vm.exists(path)) return readDeploymentByPath(path);
    deployment.aliasName = aliasName;
  }

  /// @notice Persist a deployment record to config/deployments/<alias>.json.
  function writeDeployment(
    Types.Deployment memory deployment
  ) internal {
    vm.createDir(DEPLOYMENTS_DIR, true); // idempotent
    writeDeploymentByPath(deploymentPath(deployment.aliasName), deployment);
  }

  /// @notice Persist a deployment record to an explicit path (used by tests).
  function writeDeploymentByPath(
    string memory path,
    Types.Deployment memory deployment
  ) internal {
    string memory entries = "";
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      string memory entry = string.concat(
        "{\"versionTag\":\"",
        tagToString(deployment.verifiers[i].versionTag),
        "\",\"address\":\"",
        vm.toString(deployment.verifiers[i].addr),
        "\"}"
      );
      entries = string.concat(entries, i == 0 ? "" : ",", entry);
    }
    string memory json = string.concat(
      "{\"alias\":\"",
      deployment.aliasName,
      "\",\"factory\":\"",
      vm.toString(deployment.factory),
      "\",\"resolver\":\"",
      vm.toString(deployment.resolver),
      "\",\"verifiers\":[",
      entries,
      "]}"
    );
    vm.writeJson(json, path);
  }

  // --------------------------------------------------------------------------
  //  bytes4 parsing
  // --------------------------------------------------------------------------
  /// @dev Parse a 4-byte hex string (e.g. "0x00010001") into bytes4 unambiguously.
  ///      Uses parseJsonBytes (dynamic) + explicit big-endian reconstruction, so the
  ///      result does not depend on Foundry's fixed-bytes padding convention.
  function _parseBytes4(
    string memory json,
    string memory key
  ) private pure returns (bytes4) {
    bytes memory raw = vm.parseJsonBytes(json, key);
    require(raw.length == 4, "ConfigLib: expected a 4-byte hex value");
    return _toBytes4(raw);
  }

  function _toBytes4(
    bytes memory raw
  ) private pure returns (bytes4 result) {
    uint32 accumulated = 0;
    for (uint256 i = 0; i < 4; ++i) {
      accumulated = (accumulated << 8) | uint32(uint8(raw[i]));
    }
    result = bytes4(accumulated);
  }

  /// @notice Renders a versionTag as "0x00010001". `vm.toString(bytes4)` is a trap: the
  ///         argument widens to bytes32 and prints 64 hex chars.
  function tagToString(
    bytes4 tag
  ) internal pure returns (string memory) {
    bytes memory raw = new bytes(4);
    for (uint256 i = 0; i < 4; ++i) {
      raw[i] = tag[i];
    }
    return vm.toString(raw);
  }

  // --------------------------------------------------------------------------
  //  range-checked narrowing
  // --------------------------------------------------------------------------
  /// @dev Config numbers are hand-edited, so a bare downcast turns an out-of-range value
  ///      into a valid-looking smaller one with no error. A typo'd extra digit on a chain
  ///      selector is the dangerous case: any uint64 is a syntactically valid selector, so
  ///      nothing downstream can catch it and the lane targets the wrong chain.
  function _toUint64(
    uint256 value,
    string memory key
  ) private pure returns (uint64) {
    require(value <= type(uint64).max, string.concat("ConfigLib: ", key, " exceeds uint64"));
    // casting to 'uint64' is safe because the require above bounds `value`
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint64(value);
  }

  function _toUint32(
    uint256 value,
    string memory key
  ) private pure returns (uint32) {
    require(value <= type(uint32).max, string.concat("ConfigLib: ", key, " exceeds uint32"));
    // casting to 'uint32' is safe because the require above bounds `value`
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint32(value);
  }

  function _toUint16(
    uint256 value,
    string memory key
  ) private pure returns (uint16) {
    require(value <= type(uint16).max, string.concat("ConfigLib: ", key, " exceeds uint16"));
    // casting to 'uint16' is safe because the require above bounds `value`
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint16(value);
  }

  function _toUint8(
    uint256 value,
    string memory key
  ) private pure returns (uint8) {
    require(value <= type(uint8).max, string.concat("ConfigLib: ", key, " exceeds uint8"));
    // casting to 'uint8' is safe because the require above bounds `value`
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint8(value);
  }

  // --------------------------------------------------------------------------
  //  small string helpers
  // --------------------------------------------------------------------------
  function _hasPrefix(
    string memory text,
    string memory prefix
  ) private pure returns (bool) {
    bytes memory textBytes = bytes(text);
    bytes memory prefixBytes = bytes(prefix);
    if (prefixBytes.length > textBytes.length) return false;
    for (uint256 i = 0; i < prefixBytes.length; ++i) {
      if (textBytes[i] != prefixBytes[i]) return false;
    }
    return true;
  }

  function _hasSuffix(
    string memory text,
    string memory suffix
  ) private pure returns (bool) {
    bytes memory textBytes = bytes(text);
    bytes memory suffixBytes = bytes(suffix);
    if (suffixBytes.length > textBytes.length) return false;
    for (uint256 i = 0; i < suffixBytes.length; ++i) {
      if (textBytes[textBytes.length - suffixBytes.length + i] != suffixBytes[i]) return false;
    }
    return true;
  }

  /// @dev Byte-wise lexicographic `left < right`, for a deterministic `listLanes` order.
  function _stringLessThan(
    string memory left,
    string memory right
  ) private pure returns (bool) {
    bytes memory leftBytes = bytes(left);
    bytes memory rightBytes = bytes(right);
    uint256 shortest = leftBytes.length < rightBytes.length ? leftBytes.length : rightBytes.length;
    for (uint256 i = 0; i < shortest; ++i) {
      if (leftBytes[i] != rightBytes[i]) return uint8(leftBytes[i]) < uint8(rightBytes[i]);
    }
    return leftBytes.length < rightBytes.length;
  }

  function _contains(
    string memory text,
    string memory needle
  ) private pure returns (bool) {
    bytes memory textBytes = bytes(text);
    bytes memory needleBytes = bytes(needle);
    if (needleBytes.length == 0 || needleBytes.length > textBytes.length) return needleBytes.length == 0;
    for (uint256 i = 0; i <= textBytes.length - needleBytes.length; ++i) {
      bool matched = true;
      for (uint256 j = 0; j < needleBytes.length; ++j) {
        if (textBytes[i + j] != needleBytes[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return true;
    }
    return false;
  }
}
