// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Types} from "./Types.sol";

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
  function readChain(string memory aliasName) internal view returns (Types.ChainConfig memory) {
    return readChainByPath(string.concat(CHAINS_DIR, aliasName, ".json"));
  }

  function readChainByPath(string memory path) internal view returns (Types.ChainConfig memory c) {
    string memory json = vm.readFile(path);
    c.aliasName = vm.parseJsonString(json, ".alias");
    c.chainId = vm.parseJsonUint(json, ".chainId");
    c.chainSelector = uint64(vm.parseUint(vm.parseJsonString(json, ".chainSelector")));
    c.rmn = vm.parseJsonAddress(json, ".rmn");
    c.versionTag = _parseBytes4(json, ".versionTag");
    c.finalityConfig = _parseBytes4(json, ".finalityConfig");
    c.storageLocations = vm.parseJsonStringArray(json, ".storageLocations");
    c.resolverSalt = vm.parseJsonBytes32(json, ".resolverSalt");
  }

  // --------------------------------------------------------------------------
  //  lanes
  // --------------------------------------------------------------------------
  /// @notice Returns the file paths of every real lane config (skips `_template`
  ///         and `*.example.json`). Feed each path to `readLaneByPath`.
  function listLanes() internal view returns (string[] memory paths) {
    Vm.DirEntry[] memory entries = vm.readDir(LANES_DIR);
    string[] memory buf = new string[](entries.length);
    uint256 n;
    for (uint256 i; i < entries.length; ++i) {
      string memory p = entries[i].path;
      if (_hasSuffix(p, ".json") && !_contains(p, "_template") && !_contains(p, ".example.")) {
        buf[n++] = p;
      }
    }
    paths = new string[](n);
    for (uint256 i; i < n; ++i) {
      paths[i] = buf[i];
    }
  }

  function readLaneByPath(string memory path) internal view returns (Types.LaneConfig memory l) {
    string memory json = vm.readFile(path);
    l.name = vm.parseJsonString(json, ".name");

    l.source.aliasName = vm.parseJsonString(json, ".source.alias");
    l.source.chainSelector = uint64(vm.parseUint(vm.parseJsonString(json, ".source.chainSelector")));
    l.dest.aliasName = vm.parseJsonString(json, ".dest.alias");
    l.dest.chainSelector = uint64(vm.parseUint(vm.parseJsonString(json, ".dest.chainSelector")));

    l.sig.threshold = uint8(vm.parseJsonUint(json, ".signatureConfig.threshold"));
    l.sig.signers = vm.parseJsonAddressArray(json, ".signatureConfig.signers");

    l.remote.router = vm.parseJsonAddress(json, ".remoteChainConfig.router");
    l.remote.allowlistEnabled = vm.parseJsonBool(json, ".remoteChainConfig.allowlistEnabled");
    l.remote.feeUSDCents = uint16(vm.parseJsonUint(json, ".remoteChainConfig.feeUSDCents"));
    l.remote.gasForVerification = uint32(vm.parseJsonUint(json, ".remoteChainConfig.gasForVerification"));
    l.remote.payloadSizeBytes = uint16(vm.parseJsonUint(json, ".remoteChainConfig.payloadSizeBytes"));

    l.allowlist.allowlistEnabled = vm.parseJsonBool(json, ".allowlist.allowlistEnabled");
    l.allowlist.added = vm.parseJsonAddressArray(json, ".allowlist.addedAllowlistedSenders");
    l.allowlist.removed = vm.parseJsonAddressArray(json, ".allowlist.removedAllowlistedSenders");
  }

  // --------------------------------------------------------------------------
  //  roles
  // --------------------------------------------------------------------------
  function readRoles(string memory aliasName) internal view returns (Types.RolesConfig memory) {
    return readRolesByPath(string.concat(ROLES_DIR, aliasName, ".json"));
  }

  /// @notice Read roles, or a zeroed struct if the file does not exist. Lets optional
  ///         steps (e.g. factory ownership handover) proceed without a roles file.
  function readRolesOrEmpty(string memory aliasName) internal view returns (Types.RolesConfig memory r) {
    string memory path = string.concat(ROLES_DIR, aliasName, ".json");
    if (vm.exists(path)) return readRolesByPath(path);
    r.aliasName = aliasName;
  }

  function readRolesByPath(string memory path) internal view returns (Types.RolesConfig memory r) {
    string memory json = vm.readFile(path);
    r.aliasName = vm.parseJsonString(json, ".alias");
    r.verifier.owner = vm.parseJsonAddress(json, ".verifier.owner");
    r.verifier.storageLocationsAdmin = vm.parseJsonAddress(json, ".verifier.storageLocationsAdmin");
    r.verifier.allowlistAdmin = vm.parseJsonAddress(json, ".verifier.allowlistAdmin");
    r.verifier.feeAggregator = vm.parseJsonAddress(json, ".verifier.feeAggregator");
    r.resolver.owner = vm.parseJsonAddress(json, ".resolver.owner");
    r.resolver.feeAggregator = vm.parseJsonAddress(json, ".resolver.feeAggregator");
    r.factoryOwner = vm.parseJsonAddress(json, ".factory.owner");
  }

  // --------------------------------------------------------------------------
  //  deployments (recorded addresses; written by the deploy scripts)
  // --------------------------------------------------------------------------
  function deploymentPath(string memory aliasName) internal pure returns (string memory) {
    return string.concat(DEPLOYMENTS_DIR, aliasName, ".json");
  }

  function readDeployment(string memory aliasName) internal view returns (Types.Deployment memory) {
    return readDeploymentByPath(deploymentPath(aliasName));
  }

  function readDeploymentByPath(string memory path) internal view returns (Types.Deployment memory d) {
    string memory json = vm.readFile(path);
    d.aliasName = vm.parseJsonString(json, ".alias");
    d.factory = vm.parseJsonAddress(json, ".factory");
    d.resolver = vm.parseJsonAddress(json, ".resolver");
    d.verifier = vm.parseJsonAddress(json, ".verifier");
  }

  /// @notice Read the deployment record, or a zeroed struct (with alias set) if the
  ///         file does not exist yet. Lets deploy scripts merge one address at a time.
  function readDeploymentOrEmpty(string memory aliasName) internal view returns (Types.Deployment memory d) {
    string memory path = deploymentPath(aliasName);
    if (vm.exists(path)) return readDeploymentByPath(path);
    d.aliasName = aliasName;
  }

  /// @notice Persist a deployment record to config/deployments/<alias>.json.
  function writeDeployment(Types.Deployment memory d) internal {
    vm.createDir(DEPLOYMENTS_DIR, true); // idempotent
    writeDeploymentByPath(deploymentPath(d.aliasName), d);
  }

  /// @notice Persist a deployment record to an explicit path (used by tests).
  function writeDeploymentByPath(string memory path, Types.Deployment memory d) internal {
    string memory obj = "ccv_deployment";
    vm.serializeString(obj, "alias", d.aliasName);
    vm.serializeAddress(obj, "factory", d.factory);
    vm.serializeAddress(obj, "resolver", d.resolver);
    string memory out = vm.serializeAddress(obj, "verifier", d.verifier);
    vm.writeJson(out, path);
  }

  // --------------------------------------------------------------------------
  //  bytes4 parsing
  // --------------------------------------------------------------------------
  /// @dev Parse a 4-byte hex string (e.g. "0x00010001") into bytes4 unambiguously.
  ///      Uses parseJsonBytes (dynamic) + explicit big-endian reconstruction, so the
  ///      result does not depend on Foundry's fixed-bytes padding convention.
  function _parseBytes4(string memory json, string memory key) private pure returns (bytes4 out) {
    bytes memory raw = vm.parseJsonBytes(json, key);
    require(raw.length == 4, "ConfigLib: expected a 4-byte hex value");
    uint32 acc;
    for (uint256 i; i < 4; ++i) {
      acc = (acc << 8) | uint32(uint8(raw[i]));
    }
    out = bytes4(acc);
  }

  // --------------------------------------------------------------------------
  //  small string helpers
  // --------------------------------------------------------------------------
  function _hasSuffix(string memory s, string memory suffix) private pure returns (bool) {
    bytes memory b = bytes(s);
    bytes memory suf = bytes(suffix);
    if (suf.length > b.length) return false;
    for (uint256 i; i < suf.length; ++i) {
      if (b[b.length - suf.length + i] != suf[i]) return false;
    }
    return true;
  }

  function _contains(string memory s, string memory needle) private pure returns (bool) {
    bytes memory b = bytes(s);
    bytes memory n = bytes(needle);
    if (n.length == 0 || n.length > b.length) return n.length == 0;
    for (uint256 i; i <= b.length - n.length; ++i) {
      bool ok = true;
      for (uint256 j; j < n.length; ++j) {
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