// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AcceptOwnership} from "../../script/ownership/AcceptOwnership.s.sol";
import {AcceptStorageLocationsAdmin} from "../../script/ownership/AcceptStorageLocationsAdmin.s.sol";
import {CancelOwnership} from "../../script/ownership/CancelOwnership.s.sol";
import {CancelStorageLocationsAdmin} from "../../script/ownership/CancelStorageLocationsAdmin.s.sol";
import {TransferOwnership} from "../../script/ownership/TransferOwnership.s.sol";
import {TransferStorageLocationsAdmin} from "../../script/ownership/TransferStorageLocationsAdmin.s.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {Ownable2Step} from "@chainlink/contracts/src/v0.8/shared/access/Ownable2Step.sol";
import {IOwnable} from "@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol";

/// @title OwnershipTest
/// @notice Covers the ownership + storage-locations-admin ceremonies
///         against the real audited contracts.
contract OwnershipTest is CommitteeVerifierSetup {
  TransferOwnership internal transferOwner;
  AcceptOwnership internal acceptOwner;
  TransferStorageLocationsAdmin internal transferSla;
  AcceptStorageLocationsAdmin internal acceptSla;
  CancelOwnership internal cancelOwner;
  CancelStorageLocationsAdmin internal cancelSla;

  address internal constant NEW_OWNER = address(0x0117);
  address internal constant NEW_ADMIN = address(0x0AD3);
  address internal constant INTERLOPER = address(0xBAD);

  function setUp() public virtual override {
    super.setUp();
    transferOwner = new TransferOwnership();
    acceptOwner = new AcceptOwnership();
    transferSla = new TransferStorageLocationsAdmin();
    acceptSla = new AcceptStorageLocationsAdmin();
    cancelOwner = new CancelOwnership();
    cancelSla = new CancelStorageLocationsAdmin();
  }

  // ===========================================================================
  //  TransferOwnership / AcceptOwnership — the two-step property
  // ===========================================================================

  /// @dev The whole point of two-step: proposing must NOT hand over control. If this
  ///      ever regressed to a one-step transfer, a typo'd address would be terminal.
  function test_transferOwnership_doesNotChangeOwnerImmediately() public {
    _exec(transferOwner.callsFor(address(verifier), NEW_OWNER));
    assertEq(verifier.owner(), address(this), "owner must not change on propose");
  }

  function test_acceptOwnership_completesTransfer() public {
    _exec(transferOwner.callsFor(address(verifier), NEW_OWNER));
    BaseScript.Call[] memory accept = acceptOwner.callsFor(address(verifier));

    vm.prank(NEW_OWNER);
    _exec1(accept[0]);

    assertEq(verifier.owner(), NEW_OWNER, "owner must change on accept");
  }

  function test_acceptOwnership_revertsForNonPendingCaller() public {
    _exec(transferOwner.callsFor(address(verifier), NEW_OWNER));
    BaseScript.Call[] memory accept = acceptOwner.callsFor(address(verifier));

    vm.prank(INTERLOPER);
    vm.expectRevert(Ownable2Step.MustBeProposedOwner.selector);
    _exec1(accept[0]);
  }

  function test_acceptOwnership_revertsWithoutProposal() public {
    BaseScript.Call[] memory accept = acceptOwner.callsFor(address(verifier));

    vm.prank(NEW_OWNER);
    vm.expectRevert(Ownable2Step.MustBeProposedOwner.selector);
    _exec1(accept[0]);
  }

  function test_transferOwnership_worksOnResolverToo() public {
    _exec(transferOwner.callsFor(address(resolver), NEW_OWNER));
    BaseScript.Call[] memory accept = acceptOwner.callsFor(address(resolver));

    vm.prank(NEW_OWNER);
    _exec1(accept[0]);

    assertEq(resolver.owner(), NEW_OWNER, "resolver ownership is the same ceremony");
  }

  function test_transferOwnership_callsForTargetsRequestedContract() public view {
    BaseScript.Call[] memory calls = transferOwner.callsFor(address(resolver), NEW_OWNER);
    assertEq(calls.length, 1, "one call");
    assertEq(calls[0].to, address(resolver), "addressed to the requested contract");
    assertEq(calls[0].value, 0, "never sends value");
    assertEq(calls[0].data, abi.encodeCall(IOwnable.transferOwnership, (NEW_OWNER)), "calldata");
  }

  // ===========================================================================
  //  storageLocationsAdmin — a SEPARATE two-step role
  // ===========================================================================

  function test_transferStorageLocationsAdmin_setsPendingOnly() public {
    _exec(transferSla.callsFor(address(verifier), NEW_ADMIN));

    assertEq(verifier.getStorageLocationsAdmin(), address(this), "active admin unchanged on propose");
    assertEq(verifier.getPendingStorageLocationsAdmin(), NEW_ADMIN, "pending admin recorded");
  }

  function test_acceptStorageLocationsAdmin_completesAndClearsPending() public {
    _exec(transferSla.callsFor(address(verifier), NEW_ADMIN));
    BaseScript.Call[] memory accept = acceptSla.callsFor(address(verifier));

    vm.prank(NEW_ADMIN);
    _exec1(accept[0]);

    assertEq(verifier.getStorageLocationsAdmin(), NEW_ADMIN, "admin transferred");
    assertEq(verifier.getPendingStorageLocationsAdmin(), address(0), "pending cleared");
  }

  function test_acceptStorageLocationsAdmin_revertsForNonPendingCaller() public {
    _exec(transferSla.callsFor(address(verifier), NEW_ADMIN));
    BaseScript.Call[] memory accept = acceptSla.callsFor(address(verifier));

    vm.prank(INTERLOPER);
    vm.expectRevert(CommitteeVerifier.MustBeProposedStorageLocationsAdmin.selector);
    _exec1(accept[0]);
  }

  /// @dev The propose leg is gated on the CURRENT ADMIN, not the owner. Worth pinning:
  ///      after a handover these two roles can sit with different holders, and using
  ///      the owner key here would silently fail in production.
  function test_transferStorageLocationsAdmin_callerMustBeCurrentAdmin() public {
    BaseScript.Call[] memory propose = transferSla.callsFor(address(verifier), NEW_ADMIN);

    vm.prank(INTERLOPER);
    vm.expectRevert(CommitteeVerifier.OnlyCallableByStorageLocationsAdmin.selector);
    _exec1(propose[0]);
  }

  // ===========================================================================
  //  role independence — the two ceremonies must not bleed into each other
  // ===========================================================================

  function test_ownershipTransfer_doesNotMoveStorageLocationsAdmin() public {
    _exec(transferOwner.callsFor(address(verifier), NEW_OWNER));
    BaseScript.Call[] memory accept = acceptOwner.callsFor(address(verifier));

    vm.prank(NEW_OWNER);
    _exec1(accept[0]);

    assertEq(verifier.owner(), NEW_OWNER, "owner moved");
    assertEq(verifier.getStorageLocationsAdmin(), address(this), "admin must NOT follow ownership");
  }

  function test_storageLocationsAdminTransfer_doesNotMoveOwnership() public {
    _exec(transferSla.callsFor(address(verifier), NEW_ADMIN));
    BaseScript.Call[] memory accept = acceptSla.callsFor(address(verifier));

    vm.prank(NEW_ADMIN);
    _exec1(accept[0]);

    assertEq(verifier.getStorageLocationsAdmin(), NEW_ADMIN, "admin moved");
    assertEq(verifier.owner(), address(this), "ownership must NOT follow the admin role");
  }

  // ===========================================================================
  //  cancellation — clearing a mistaken or stale proposal before it is accepted
  // ===========================================================================

  /// @dev Ownable2Step has no pending-owner getter, so cancellation is proven the way
  ///      it matters: the previously proposed owner can no longer accept.
  function test_cancelOwnership_clearsPendingProposal() public {
    _exec(transferOwner.callsFor(address(verifier), NEW_OWNER));
    _exec(cancelOwner.callsFor(address(verifier)));

    BaseScript.Call[] memory accept = acceptOwner.callsFor(address(verifier));
    vm.prank(NEW_OWNER);
    vm.expectRevert(Ownable2Step.MustBeProposedOwner.selector);
    _exec1(accept[0]);

    assertEq(verifier.owner(), address(this), "cancel must not move ownership");
  }

  /// @dev A failed cancel must also leave the proposal intact, so a griefing attempt
  ///      neither clears nor moves anything.
  function test_cancelOwnership_callerMustBeCurrentOwner() public {
    _exec(transferOwner.callsFor(address(verifier), NEW_OWNER));
    BaseScript.Call[] memory cancel = cancelOwner.callsFor(address(verifier));

    vm.prank(INTERLOPER);
    vm.expectRevert(Ownable2Step.OnlyCallableByOwner.selector);
    _exec1(cancel[0]);

    BaseScript.Call[] memory accept = acceptOwner.callsFor(address(verifier));
    vm.prank(NEW_OWNER);
    _exec1(accept[0]);
    assertEq(verifier.owner(), NEW_OWNER, "proposal survives an unauthorized cancel");
  }

  /// @dev Nothing pending: re-proposing zero overwrites zero with zero.
  function test_cancelOwnership_withNothingPending_isHarmless() public {
    _exec(cancelOwner.callsFor(address(verifier)));
    assertEq(verifier.owner(), address(this), "owner unchanged");
  }

  /// @dev The zero address is deliberate and lives ONLY in the cancel script;
  ///      TransferOwnership keeps rejecting it as a proposed owner.
  function test_cancelOwnership_callsForEncodesZeroAddress() public view {
    BaseScript.Call[] memory calls = cancelOwner.callsFor(address(resolver));
    assertEq(calls.length, 1, "one call");
    assertEq(calls[0].to, address(resolver), "addressed to the requested contract");
    assertEq(calls[0].value, 0, "never sends value");
    assertEq(calls[0].data, abi.encodeCall(IOwnable.transferOwnership, (address(0))), "calldata");
  }

  function test_cancelStorageLocationsAdmin_clearsPendingProposal() public {
    _exec(transferSla.callsFor(address(verifier), NEW_ADMIN));
    assertEq(verifier.getPendingStorageLocationsAdmin(), NEW_ADMIN, "proposal in place");

    _exec(cancelSla.callsFor(address(verifier)));
    assertEq(verifier.getPendingStorageLocationsAdmin(), address(0), "pending admin cleared");

    BaseScript.Call[] memory accept = acceptSla.callsFor(address(verifier));
    vm.prank(NEW_ADMIN);
    vm.expectRevert(CommitteeVerifier.MustBeProposedStorageLocationsAdmin.selector);
    _exec1(accept[0]);

    assertEq(verifier.getStorageLocationsAdmin(), address(this), "cancel must not move the role");
  }

  function test_cancelStorageLocationsAdmin_callerMustBeCurrentAdmin() public {
    _exec(transferSla.callsFor(address(verifier), NEW_ADMIN));
    BaseScript.Call[] memory cancel = cancelSla.callsFor(address(verifier));

    vm.prank(INTERLOPER);
    vm.expectRevert(CommitteeVerifier.OnlyCallableByStorageLocationsAdmin.selector);
    _exec1(cancel[0]);

    assertEq(verifier.getPendingStorageLocationsAdmin(), NEW_ADMIN, "proposal survives an unauthorized cancel");
  }

  // ===========================================================================
  //  full ceremony via the per-target scripts
  // ===========================================================================

  /// @dev Each party prepares its own leg: the current holders execute the a- batches,
  ///      the incoming holders their b- batches. All three roles move independently.
  function test_fullHandover_movesEveryRole() public {
    _exec(transferOwner.callsFor(address(verifier), NEW_OWNER));
    _exec(transferOwner.callsFor(address(resolver), NEW_OWNER));
    _exec(transferSla.callsFor(address(verifier), NEW_ADMIN));

    BaseScript.Call[] memory acceptVerifier = acceptOwner.callsFor(address(verifier));
    BaseScript.Call[] memory acceptResolver = acceptOwner.callsFor(address(resolver));
    BaseScript.Call[] memory acceptSlaCall = acceptSla.callsFor(address(verifier));

    vm.prank(NEW_OWNER);
    _exec1(acceptVerifier[0]);
    vm.prank(NEW_OWNER);
    _exec1(acceptResolver[0]);
    vm.prank(NEW_ADMIN);
    _exec1(acceptSlaCall[0]);

    assertEq(verifier.owner(), NEW_OWNER, "verifier owner");
    assertEq(resolver.owner(), NEW_OWNER, "resolver owner");
    assertEq(verifier.getStorageLocationsAdmin(), NEW_ADMIN, "storage locations admin");
    assertEq(verifier.getPendingStorageLocationsAdmin(), address(0), "no pending admin left");
  }

  // ===========================================================================
  //  factory leg — completes the transfer BootstrapFactory proposes
  // ===========================================================================

  /// @dev Until this leg exists the deployer EOA stays factory owner, and
  ///      applyAllowListUpdates is onlyOwner — so the deployer key cannot be revoked
  ///      without giving up control of who may claim CREATE2 addresses.
  function test_acceptOwnership_run_completesFactoryHandover() public {
    factory.transferOwnership(DEFAULT_SENDER);
    assertEq(factory.owner(), address(this), "propose does not move ownership");

    ConfigLib.writeDeployment(
      Types.Deployment({
        aliasName: ALIAS_FACTORY, factory: address(factory), resolver: address(resolver), verifier: address(verifier)
      })
    );

    // run() reads OUTPUT_MODE, which deliberately has no default. setEnv is process-global
    // and memoised by forge, but this is the suite's only env-path run() call.
    vm.setEnv("OUTPUT_MODE", "EOA");
    acceptOwner.run(ALIAS_FACTORY, "factory");

    assertEq(factory.owner(), DEFAULT_SENDER, "factory ownership accepted");
  }

  function test_transferOwnership_callsFor_targetsFactory() public view {
    BaseScript.Call[] memory calls = transferOwner.callsFor(address(factory), NEW_OWNER);
    assertEq(calls[0].to, address(factory), "addressed to the factory");
    assertEq(calls[0].data, abi.encodeCall(IOwnable.transferOwnership, (NEW_OWNER)), "calldata");
  }

  // ===========================================================================
  //  helpers
  // ===========================================================================

  /// @dev In-memory only — the handover seams take structs, so this alias never hits disk.
  ///      Named like the rest for uniformity; zz-scratch-* is the repo-wide fixture marker.
  string internal constant ALIAS = "zz-scratch-ownership-chain";

  /// @dev Any test that calls `ConfigLib.writeDeployment` needs its OWN alias. Foundry
  ///      runs test functions concurrently against a shared filesystem, so two tests
  ///      writing `config/deployments/<alias>.json` race: one overwrites the other's
  ///      fixture mid-run and the failure looks like a contract bug, not a test bug.
  ///      `writeDeployment` targets the real config directory, so these must keep the
  ///      zz-scratch- prefix the governance tooling skips.
  string internal constant ALIAS_DISPATCH = "zz-scratch-ownership-dispatch";
  string internal constant ALIAS_REJECT = "zz-scratch-ownership-reject";
  string internal constant ALIAS_FACTORY = "zz-scratch-ownership-factory";

  function _deployment() internal view returns (Types.Deployment memory deployment) {
    deployment.aliasName = ALIAS;
    deployment.factory = address(factory);
    deployment.resolver = address(resolver);
    deployment.verifier = address(verifier);
  }

  function _roles() internal pure returns (Types.RolesConfig memory roles) {
    roles.aliasName = ALIAS;
    roles.verifier.owner = NEW_OWNER;
    roles.verifier.storageLocationsAdmin = NEW_ADMIN;
    roles.resolver.owner = NEW_OWNER;
    roles.factoryOwner = NEW_OWNER;
  }

  /// @dev Executes staged calls in order. NOTE: `vm.prank` applies to the next EXTERNAL
  ///      call, and a `script.callsFor(...)` in an argument position is itself external —
  ///      so always hoist the builder into a local BEFORE pranking, then send one call
  ///      per prank with `_exec1`. Getting this wrong silently executes the ceremony as
  ///      the test contract and the assertion fails far from the cause.
  function _exec(
    BaseScript.Call[] memory calls
  ) internal {
    for (uint256 i = 0; i < calls.length; ++i) {
      // a generic executor: the destination is caller-supplied by design
      // forge-lint: disable-next-line(arbitrary-send-eth)
      (bool ok, bytes memory ret) = calls[i].to.call{value: calls[i].value}(calls[i].data);
      if (!ok) _bubble(ret);
    }
  }

  function _exec1(
    BaseScript.Call memory call
  ) internal {
    // a generic executor: the destination is caller-supplied by design
    // forge-lint: disable-next-line(arbitrary-send-eth)
    (bool ok, bytes memory ret) = call.to.call{value: call.value}(call.data);
    if (!ok) _bubble(ret);
  }

  function _bubble(
    bytes memory ret
  ) private pure {
    if (ret.length > 0) {
      // solhint-disable-next-line no-inline-assembly
      assembly {
        revert(add(ret, 0x20), mload(ret))
      }
    }
    revert("Ownership test: call reverted without data");
  }
}
