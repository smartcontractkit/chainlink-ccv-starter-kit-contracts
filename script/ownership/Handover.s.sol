// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {AcceptOwnership} from "./AcceptOwnership.s.sol";
import {AcceptStorageLocationsAdmin} from "./AcceptStorageLocationsAdmin.s.sol";
import {TransferOwnership} from "./TransferOwnership.s.sol";
import {TransferStorageLocationsAdmin} from "./TransferStorageLocationsAdmin.s.sol";
import {console2} from "forge-std/console2.sol";

/// @title Handover
/// @notice Outline step 13 orchestration. Emits the full handover as THREE ordered,
///         separate Safe batches so a signer cannot execute steps out of order and
///         permanently lock a contract:
///
///           a-handover-propose   : current holders propose all transfers
///                                    - verifier.transferOwnership(newOwner)
///                                    - resolver.transferOwnership(newOwner)
///                                    - verifier.transferStorageLocationsAdmin(newAdmin)
///           b-handover-accept    : NEW holders accept (run by the incoming Safe(s))
///                                    - verifier.acceptOwnership()
///                                    - resolver.acceptOwnership()
///                                    - verifier.acceptStorageLocationsAdmin()
///           c-handover-finalize  : cleanup of any transitional roles, run ONLY after
///                                  on-chain acceptance is confirmed (grant-new-
///                                  before-revoke-old). See TODO below.
///
/// @dev The two-step (transfer + accept) pattern means acceptance itself revokes the
///      old owner/admin, so there is no separate "revoke" tx for owner/admin. The
///      c- batch is reserved for revoking any DEPLOYER-held transitional roles that
///      are NOT two-step (e.g. re-pointing DynamicConfig.allowlistAdmin / feeAggregator
///      to final governance via setDynamicConfig).
///
/// @dev In EOA mode only the propose leg (a-) is executed, because accept must come
///      from the new holders. Run this in SAFE mode to generate all three batches.
///
/// @dev This orchestrator does NOT re-implement the calldata. It reuses the `callsFor`
///      builders on the individual ownership scripts (TransferOwnership,
///      AcceptOwnership, TransferStorageLocationsAdmin, AcceptStorageLocationsAdmin),
///      so any future change to how an operation is encoded propagates here for free.
///
/// Usage (Phase 2):
///   OUTPUT_MODE=SAFE SAFE_ADDRESS=0x<currentOwnerSafe> \
///     forge script script/ownership/Handover.s.sol --sig "run(string)" sepolia
contract Handover is BaseScript {
  function run(
    string calldata chainAlias
  ) external {
    _initOutput();

    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);

    require(dep.verifier != address(0) && dep.resolver != address(0), "Handover: contracts not deployed");
    require(roles.verifier.owner != address(0), "Handover: verifier owner role unset");
    require(roles.resolver.owner != address(0), "Handover: resolver owner role unset");
    require(roles.verifier.storageLocationsAdmin != address(0), "Handover: storageLocationsAdmin role unset");

    bool safe = outputMode == OutputMode.SAFE;

    // Reuse the per-operation call builders (single source of truth for the calldata).
    TransferOwnership transferOwner = new TransferOwnership();
    AcceptOwnership acceptOwner = new AcceptOwnership();
    TransferStorageLocationsAdmin transferSla = new TransferStorageLocationsAdmin();
    AcceptStorageLocationsAdmin acceptSla = new AcceptStorageLocationsAdmin();

    // ---- a) propose (current holders) ----
    _stageMany(transferOwner.callsFor(dep.verifier, roles.verifier.owner));
    _stageMany(transferOwner.callsFor(dep.resolver, roles.resolver.owner));
    _stageMany(transferSla.callsFor(dep.verifier, roles.verifier.storageLocationsAdmin));
    _flush("a-handover-propose");

    if (!safe) {
      console2.log("[Handover] EOA mode: only the propose leg ran.");
      console2.log("[Handover] accept + finalize must be executed by the NEW holders (use SAFE mode).");
      return;
    }

    // ---- b) accept (new holders) ----
    _stageMany(acceptOwner.callsFor(dep.verifier));
    _stageMany(acceptOwner.callsFor(dep.resolver));
    _stageMany(acceptSla.callsFor(dep.verifier));
    _flush("b-handover-accept");

    // ---- c) finalize / revoke transitional roles (run AFTER acceptance) ----
    // TODO(step 13): if the deployer held DynamicConfig.allowlistAdmin or a
    //   transitional feeAggregator, stage the final setDynamicConfig here so those
    //   non-two-step roles are re-pointed to governance. Left empty by default.
    _flush("c-handover-finalize");
  }
}
