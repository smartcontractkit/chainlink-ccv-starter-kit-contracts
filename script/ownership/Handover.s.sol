// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";

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
/// Usage (Phase 2):
///   OUTPUT_MODE=SAFE SAFE_ADDRESS=0x<currentOwnerSafe> \
///     forge script script/ownership/Handover.s.sol --sig "run(string)" sepolia
contract Handover is BaseScript {
  function run(string calldata chainAlias) external {
    _initOutput();

    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);

    require(dep.verifier != address(0) && dep.resolver != address(0), "Handover: contracts not deployed");
    require(roles.verifier.owner != address(0), "Handover: verifier owner role unset");
    require(roles.resolver.owner != address(0), "Handover: resolver owner role unset");
    require(roles.verifier.storageLocationsAdmin != address(0), "Handover: storageLocationsAdmin role unset");

    bool safe = outputMode == OutputMode.SAFE;

    // ---- a) propose (current holders) ----
    _stage(dep.verifier, abi.encodeWithSignature("transferOwnership(address)", roles.verifier.owner));
    _stage(dep.resolver, abi.encodeWithSignature("transferOwnership(address)", roles.resolver.owner));
    _stage(
      dep.verifier,
      abi.encodeWithSignature("transferStorageLocationsAdmin(address)", roles.verifier.storageLocationsAdmin)
    );
    _flush("a-handover-propose");

    if (!safe) {
      console2.log("[Handover] EOA mode: only the propose leg ran.");
      console2.log("[Handover] accept + finalize must be executed by the NEW holders (use SAFE mode).");
      return;
    }

    // ---- b) accept (new holders) ----
    _stage(dep.verifier, abi.encodeWithSignature("acceptOwnership()"));
    _stage(dep.resolver, abi.encodeWithSignature("acceptOwnership()"));
    _stage(dep.verifier, abi.encodeWithSignature("acceptStorageLocationsAdmin()"));
    _flush("b-handover-accept");

    // ---- c) finalize / revoke transitional roles (run AFTER acceptance) ----
    // TODO(step 13): if the deployer held DynamicConfig.allowlistAdmin or a
    //   transitional feeAggregator, stage the final setDynamicConfig here so those
    //   non-two-step roles are re-pointed to governance. Left empty by default.
    _flush("c-handover-finalize");
  }
}
