// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";

/// @title UpdateStorageLocations
/// @notice Outline step 12. Sets/updates the verifier's storage locations (the
///         operator's aggregator endpoint URL). Separate, standalone update script.
/// @dev Target call (grounded): CommitteeVerifier.updateStorageLocations(string[]).
///      CALLER IS THE storageLocationsAdmin, NOT the owner. This is a distinct,
///      two-step-transferable admin role from the contract owner.
/// @dev storageLocations is a per-deployment cross-workstream input (the deployed
///      aggregator hostname from the infra/off-chain team). It does not gate the
///      acceptance-test flow — the CCIP indexer learns endpoints from its own
///      config today — but it is the canonical on-chain record.
contract UpdateStorageLocations is BaseScript {
  bytes4 internal constant SELECTOR = CommitteeVerifier.updateStorageLocations.selector;

  function run(string calldata chainAlias) external {
    _initOutput();

    Types.ChainConfig memory cc = ConfigLib.readChain(chainAlias);
    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);

    console2.log("[UpdateStorageLocations] chain:", chainAlias);
    console2.log("  target verifier:", dep.verifier);
    console2.log("  storageLocations count:", cc.storageLocations.length);

    // NOTE: in SAFE mode this batch must be signed by the storageLocationsAdmin Safe.
    // TODO(step 12): _stage(dep.verifier,
    //   abi.encodeCall(CommitteeVerifier.updateStorageLocations, (cc.storageLocations)));

    _flush("update-storage-locations");
  }
}
