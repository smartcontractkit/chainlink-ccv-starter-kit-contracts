// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {console2} from "forge-std/console2.sol";

/// @title UpdateStorageLocations
/// @notice Sets/updates the verifier's storage locations (the
///         operator's aggregator endpoint URL(s)). Standalone update script, per chain.
///         CALLER MUST BE THE storageLocationsAdmin, NOT the owner (else reverts
///         OnlyCallableByStorageLocationsAdmin).
///
/// Usage (versionTag selects which recorded verifier to update):
///   OUTPUT_MODE=SAFE forge script script/configure/UpdateStorageLocations.s.sol \
///     --sig "run(string,bytes4)" sepolia 0x00010001 --rpc-url $SEPOLIA_RPC_URL
contract UpdateStorageLocations is BaseScript {
  /// @notice Single source of truth for the updateStorageLocations calldata.
  function callsFor(
    address verifier,
    string[] memory locations
  ) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] =
      Call({to: verifier, value: 0, data: abi.encodeCall(CommitteeVerifier.updateStorageLocations, (locations))});
  }

  function run(
    string calldata chainAlias,
    bytes4 versionTag
  ) external {
    _initOutput(chainAlias);

    Types.ChainConfig memory chainConfig = ConfigLib.readChain(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    address verifier = ConfigLib.verifierByTag(deployment, versionTag);
    _assertReachable(verifier, "verifier");

    console2.log("[UpdateStorageLocations] chain:", chainAlias);
    console2.log("  versionTag:", ConfigLib.tagToString(versionTag));
    console2.log("  target verifier:", verifier);
    console2.log("  storageLocations count:", chainConfig.storageLocations.length);

    if (chainConfig.storageLocations.length == 0) {
      console2.log("  WARN storageLocations is empty (clears the on-chain record)");
    }

    _stageMany(callsFor(verifier, chainConfig.storageLocations));
    _flush(string.concat("update-storage-locations-", ConfigLib.tagToString(versionTag)));
  }
}
