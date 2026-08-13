// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";

/// @title SnapshotRoles
/// @notice Outline step 16. Bootstraps the roles-as-data file for a chain FROM LIVE
///         on-chain state, so an operator can capture the current reality and then
///         edit toward the desired intent.
/// @dev Reads the deployment addresses, queries the on-chain getters, and writes
///      config/roles/<alias>.json. Owner reads are implemented (Ownable2Step
///      `owner()`); the remaining getters are marked TODO.
///
/// Usage:
///   forge script script/governance/SnapshotRoles.s.sol --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
contract SnapshotRoles is Script {
  function run(string calldata chainAlias) external {
    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    require(dep.verifier != address(0) && dep.resolver != address(0), "SnapshotRoles: contracts not deployed");

    address verifierOwner = _owner(dep.verifier);
    address resolverOwner = _owner(dep.resolver);

    console2.log("[SnapshotRoles] chain:", chainAlias);
    console2.log("  verifier owner:", verifierOwner);
    console2.log("  resolver owner:", resolverOwner);

    // TODO(step 16): read the remaining live roles and write the JSON:
    //   - verifier storageLocationsAdmin (needs a public getter; add one or infer from events)
    //   - verifier DynamicConfig {feeAggregator, allowlistAdmin} (getDynamicConfig)
    //   - resolver feeAggregator getter
    //   - factory owner
    // Then serialize with vm.serializeAddress(...) / vm.writeJson(...) to
    //   config/roles/<alias>.json (or a .snapshot.json for review before promotion).

    // Placeholder write so the pattern is in place:
    vm.createDir("out/governance", true); // idempotent; survives a fresh clone
    string memory obj = "roles";
    vm.serializeAddress(obj, "verifierOwner", verifierOwner);
    string memory out = vm.serializeAddress(obj, "resolverOwner", resolverOwner);
    vm.writeJson(out, string.concat("out/governance/", chainAlias, ".snapshot.local.json"));
  }

  function _owner(address target) internal view returns (address o) {
    (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("owner()"));
    if (ok && ret.length == 32) o = abi.decode(ret, (address));
  }
}