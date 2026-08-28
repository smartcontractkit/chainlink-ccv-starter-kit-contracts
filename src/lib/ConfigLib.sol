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
    chainConfig.versionTag = _parseBytes4(json, ".versionTag");
    chainConfig.finalityConfig = _parseBytes4(json, ".finalityConfig");
    chainConfig.storageLocations = vm.parseJsonStringArray(json, ".storageLocations");
    // Optional by design: fee sweeping is opt-in per chain, and the token list mirrors a
    // Chainlink-governed set (see config/README.md). A chain whose list is not decided yet
    // must still load for every other script, so absent => empty => fee scripts no-op.
    chainConfig.feeTokens =
      vm.keyExistsJson(json, ".feeTokens") ? vm.parseJsonAddressArray(json, ".feeTokens") : new address[](0);
    chainConfig.resolverSalt = vm.parseJsonBytes32(json, ".resolverSalt");
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
    roles.verifier.owner = vm.parseJsonAddress(json, ".verifier.owner");
    roles.verifier.storageLocationsAdmin = vm.parseJsonAddress(json, ".verifier.storageLocationsAdmin");
    roles.verifier.allowlistAdmin = vm.parseJsonAddress(json, ".verifier.allowlistAdmin");
    roles.verifier.feeAggregator = vm.parseJsonAddress(json, ".verifier.feeAggregator");
    roles.resolver.owner = vm.parseJsonAddress(json, ".resolver.owner");
    roles.resolver.feeAggregator = vm.parseJsonAddress(json, ".resolver.feeAggregator");
    roles.factoryOwner = vm.parseJsonAddress(json, ".factory.owner");
  }

  // --------------------------------------------------------------------------
  //  target resolution ("verifier" | "resolver" | "factory")
  // --------------------------------------------------------------------------
  /// @notice Maps a target name to its address in the deployment record.
  function targetAddress(
    Types.Deployment memory deployment,
    string memory target
  ) internal pure returns (address) {
    if (_stringsEqual(target, "verifier")) return deployment.verifier;
    if (_stringsEqual(target, "resolver")) return deployment.resolver;
    if (_stringsEqual(target, "factory")) return deployment.factory;
    revert(_unknownTarget(target));
  }

  /// @notice Maps a target name to the owner declared for it in `config/roles`.
  function targetOwner(
    Types.RolesConfig memory roles,
    string memory target
  ) internal pure returns (address) {
    if (_stringsEqual(target, "verifier")) return roles.verifier.owner;
    if (_stringsEqual(target, "resolver")) return roles.resolver.owner;
    if (_stringsEqual(target, "factory")) return roles.factoryOwner;
    revert(_unknownTarget(target));
  }

  function _unknownTarget(
    string memory target
  ) private pure returns (string memory) {
    return string.concat("ConfigLib: unknown target '", target, "' (expected verifier|resolver|factory)");
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
    deployment.verifier = vm.parseJsonAddress(json, ".verifier");
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
    string memory objectKey = "ccv_deployment";
    vm.serializeString(objectKey, "alias", deployment.aliasName);
    vm.serializeAddress(objectKey, "factory", deployment.factory);
    vm.serializeAddress(objectKey, "resolver", deployment.resolver);
    string memory json = vm.serializeAddress(objectKey, "verifier", deployment.verifier);
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
  ) private pure returns (bytes4 result) {
    bytes memory raw = vm.parseJsonBytes(json, key);
    require(raw.length == 4, "ConfigLib: expected a 4-byte hex value");
    uint32 accumulated = 0;
    for (uint256 i = 0; i < 4; ++i) {
      accumulated = (accumulated << 8) | uint32(uint8(raw[i]));
    }
    result = bytes4(accumulated);
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
