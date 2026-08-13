// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";

/// @title DriftCheck
/// @notice Outline step 16. READ-ONLY comparison of declared roles + full config
///         against on-chain getters. Designed to be CI-schedulable with DISTINCT
///         exit codes for clean / drift / RPC-unavailable — see drift-check.sh,
///         which maps this script's outcome to codes 0 / 1 / 2.
///
/// @dev Convention: on ANY drift, log a line beginning with the marker `DRIFT_DETECTED`
///      and revert. The wrapper greps for that marker to distinguish real drift
///      (exit 1) from an RPC/connection failure (exit 2). A clean run returns
///      normally (exit 0).
///
/// Usage (direct):
///   forge script script/governance/DriftCheck.s.sol --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
/// Usage (CI, with exit-code mapping):
///   script/governance/drift-check.sh sepolia $SEPOLIA_RPC_URL
contract DriftCheck is Script {
  error DriftDetected(uint256 count);

  function run(string calldata chainAlias) external view {
    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);

    uint256 drift;

    drift += _checkOwner("verifier", dep.verifier, roles.verifier.owner);
    drift += _checkOwner("resolver", dep.resolver, roles.resolver.owner);

    // TODO(step 16): extend to the FULL config, not just owners:
    //   - verifier DynamicConfig {feeAggregator, allowlistAdmin} vs roles
    //   - verifier storageLocationsAdmin vs roles
    //   - resolver feeAggregator vs roles
    //   - per-lane: applySignatureConfigs signer set + threshold vs config/lanes
    //   - per-lane: remote chain config (router/fee/gas/payload) vs config/lanes
    //   - resolver inbound/outbound implementation mappings vs deployments
    // Each mismatch: console2.log("DRIFT_DETECTED ...") and ++drift.

    if (drift > 0) {
      console2.log("DRIFT_DETECTED total mismatches:", drift);
      revert DriftDetected(drift);
    }
    console2.log("[DriftCheck] clean:", chainAlias);
  }

  function _checkOwner(string memory label, address target, address expected) internal view returns (uint256) {
    if (target == address(0)) return 0;
    (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("owner()"));
    require(ok && ret.length == 32, "DriftCheck: owner() call failed (RPC or wrong address)");
    address actual = abi.decode(ret, (address));
    if (actual != expected) {
      console2.log(string.concat("DRIFT_DETECTED owner ", label));
      console2.log("  expected:", expected);
      console2.log("  actual:  ", actual);
      return 1;
    }
    return 0;
  }
}
