// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";

/// @title UpdateStorageLocations
/// @notice Sets/updates the verifier's storage locations (the
///         operator's aggregator endpoint URL(s)). Standalone update script, per chain.
///         CALLER MUST BE THE storageLocationsAdmin, NOT the owner (else reverts
///         OnlyCallableByStorageLocationsAdmin).
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/UpdateStorageLocations.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
///   NOTE: in SAFE mode the batch MUST be signed by the storageLocationsAdmin Safe,
///         NOT the owner Safe.
contract UpdateStorageLocations is BaseScript {
  /// @notice Single source of truth for the updateStorageLocations calldata.
  function callsFor(address verifier, string[] memory locations) public pure returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({
      to: verifier,
      value: 0,
      data: abi.encodeWithSelector(CommitteeVerifier.updateStorageLocations.selector, locations)
    });
  }

  function run(string calldata chainAlias) external {
    _initOutput();

    Types.ChainConfig memory cc = ConfigLib.readChain(chainAlias);
    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    require(dep.verifier != address(0), string.concat("UpdateStorageLocations: verifier not recorded for ", chainAlias));

    console2.log("[UpdateStorageLocations] chain:", chainAlias);
    console2.log("  target verifier:", dep.verifier);
    console2.log("  storageLocations count:", cc.storageLocations.length);

    if (cc.storageLocations.length == 0) {
      console2.log("  WARN storageLocations is empty (clears the on-chain record)");
    }

    _stageMany(callsFor(dep.verifier, cc.storageLocations));
    _flush("update-storage-locations");
  }
}