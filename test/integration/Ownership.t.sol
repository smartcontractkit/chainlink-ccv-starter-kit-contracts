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
    _exec(transferOwner.callFor(address(verifier), NEW_OWNER));
    assertEq(verifier.owner(), address(this), "owner must not change on propose");
  }

  function test_acceptOwnership_completesTransfer() public {
    _exec(transferOwner.callFor(address(verifier), NEW_OWNER));
    BaseScript.Call memory accept = acceptOwner.callFor(address(verifier));

    vm.prank(NEW_OWNER);
    _exec(accept);

    assertEq(verifier.owner(), NEW_OWNER, "owner must change on accept");
  }

  function test_acceptOwnership_revertsForNonPendingCaller() public {
    _exec(transferOwner.callFor(address(verifier), NEW_OWNER));
    BaseScript.Call memory accept = acceptOwner.callFor(address(verifier));

    vm.prank(INTERLOPER);
    vm.expectRevert(Ownable2Step.MustBeProposedOwner.selector);
    _exec(accept);
  }

  function test_acceptOwnership_revertsWithoutProposal() public {
    BaseScript.Call memory accept = acceptOwner.callFor(address(verifier));

    vm.prank(NEW_OWNER);
    vm.expectRevert(Ownable2Step.MustBeProposedOwner.selector);
    _exec(accept);
  }

  function test_transferOwnership_worksOnResolverToo() public {
    _exec(transferOwner.callFor(address(resolver), NEW_OWNER));
    BaseScript.Call memory accept = acceptOwner.callFor(address(resolver));

    vm.prank(NEW_OWNER);
    _exec(accept);

    assertEq(resolver.owner(), NEW_OWNER, "resolver ownership is the same ceremony");
  }

  function test_transferOwnership_callForTargetsRequestedContract() public view {
    BaseScript.Call memory call = transferOwner.callFor(address(resolver), NEW_OWNER);
    assertEq(call.to, address(resolver), "addressed to the requested contract");
    assertEq(call.value, 0, "never sends value");
    assertEq(call.data, abi.encodeCall(IOwnable.transferOwnership, (NEW_OWNER)), "calldata");
  }

  // ===========================================================================
  //  storageLocationsAdmin — a SEPARATE two-step role
  // ===========================================================================

  function test_transferStorageLocationsAdmin_setsPendingOnly() public {
    _exec(transferSla.callFor(address(verifier), NEW_ADMIN));

    assertEq(verifier.getStorageLocationsAdmin(), address(this), "active admin unchanged on propose");
    assertEq(verifier.getPendingStorageLocationsAdmin(), NEW_ADMIN, "pending admin recorded");
  }

  function test_acceptStorageLocationsAdmin_completesAndClearsPending() public {
    _exec(transferSla.callFor(address(verifier), NEW_ADMIN));
    BaseScript.Call memory accept = acceptSla.callFor(address(verifier));

    vm.prank(NEW_ADMIN);
    _exec(accept);

    assertEq(verifier.getStorageLocationsAdmin(), NEW_ADMIN, "admin transferred");
    assertEq(verifier.getPendingStorageLocationsAdmin(), address(0), "pending cleared");
  }

  function test_acceptStorageLocationsAdmin_revertsForNonPendingCaller() public {
    _exec(transferSla.callFor(address(verifier), NEW_ADMIN));
    BaseScript.Call memory accept = acceptSla.callFor(address(verifier));

    vm.prank(INTERLOPER);
    vm.expectRevert(CommitteeVerifier.MustBeProposedStorageLocationsAdmin.selector);
    _exec(accept);
  }

  /// @dev The propose leg is gated on the CURRENT ADMIN, not the owner. Worth pinning:
  ///      after a handover these two roles can sit with different holders, and using
  ///      the owner key here would silently fail in production.
  function test_transferStorageLocationsAdmin_callerMustBeCurrentAdmin() public {
    BaseScript.Call memory propose = transferSla.callFor(address(verifier), NEW_ADMIN);

    vm.prank(INTERLOPER);
    vm.expectRevert(CommitteeVerifier.OnlyCallableByStorageLocationsAdmin.selector);
    _exec(propose);
  }

  // ===========================================================================
  //  role independence — the two ceremonies must not bleed into each other
  // ===========================================================================

  function test_ownershipTransfer_doesNotMoveStorageLocationsAdmin() public {
    _exec(transferOwner.callFor(address(verifier), NEW_OWNER));
    BaseScript.Call memory accept = acceptOwner.callFor(address(verifier));

    vm.prank(NEW_OWNER);
    _exec(accept);

    assertEq(verifier.owner(), NEW_OWNER, "owner moved");
    assertEq(verifier.getStorageLocationsAdmin(), address(this), "admin must NOT follow ownership");
  }

  function test_storageLocationsAdminTransfer_doesNotMoveOwnership() public {
    _exec(transferSla.callFor(address(verifier), NEW_ADMIN));
    BaseScript.Call memory accept = acceptSla.callFor(address(verifier));

    vm.prank(NEW_ADMIN);
    _exec(accept);

    assertEq(verifier.getStorageLocationsAdmin(), NEW_ADMIN, "admin moved");
    assertEq(verifier.owner(), address(this), "ownership must NOT follow the admin role");
  }

  // ===========================================================================
  //  cancellation — clearing a mistaken or stale proposal before it is accepted
  // ===========================================================================

  /// @dev Ownable2Step has no pending-owner getter, so cancellation is proven the way
  ///      it matters: the previously proposed owner can no longer accept.
  function test_cancelOwnership_clearsPendingProposal() public {
    _exec(transferOwner.callFor(address(verifier), NEW_OWNER));
    _exec(cancelOwner.callFor(address(verifier)));

    BaseScript.Call memory accept = acceptOwner.callFor(address(verifier));
    vm.prank(NEW_OWNER);
    vm.expectRevert(Ownable2Step.MustBeProposedOwner.selector);
    _exec(accept);

    assertEq(verifier.owner(), address(this), "cancel must not move ownership");
  }

  /// @dev A failed cancel must also leave the proposal intact, so a griefing attempt
  ///      neither clears nor moves anything.
  function test_cancelOwnership_callerMustBeCurrentOwner() public {
    _exec(transferOwner.callFor(address(verifier), NEW_OWNER));
    BaseScript.Call memory cancel = cancelOwner.callFor(address(verifier));

    vm.prank(INTERLOPER);
    vm.expectRevert(Ownable2Step.OnlyCallableByOwner.selector);
    _exec(cancel);

    BaseScript.Call memory accept = acceptOwner.callFor(address(verifier));
    vm.prank(NEW_OWNER);
    _exec(accept);
    assertEq(verifier.owner(), NEW_OWNER, "proposal survives an unauthorized cancel");
  }

  /// @dev Nothing pending: re-proposing zero overwrites zero with zero.
  function test_cancelOwnership_withNothingPending_isHarmless() public {
    _exec(cancelOwner.callFor(address(verifier)));
    assertEq(verifier.owner(), address(this), "owner unchanged");
  }

  /// @dev The zero address is deliberate and lives ONLY in the cancel script;
  ///      TransferOwnership keeps rejecting it as a proposed owner.
  function test_cancelOwnership_callForEncodesZeroAddress() public view {
    BaseScript.Call memory call = cancelOwner.callFor(address(resolver));
    assertEq(call.to, address(resolver), "addressed to the requested contract");
    assertEq(call.value, 0, "never sends value");
    assertEq(call.data, abi.encodeCall(IOwnable.transferOwnership, (address(0))), "calldata");
  }

  function test_cancelStorageLocationsAdmin_clearsPendingProposal() public {
    _exec(transferSla.callFor(address(verifier), NEW_ADMIN));
    assertEq(verifier.getPendingStorageLocationsAdmin(), NEW_ADMIN, "proposal in place");

    _exec(cancelSla.callFor(address(verifier)));
    assertEq(verifier.getPendingStorageLocationsAdmin(), address(0), "pending admin cleared");

    BaseScript.Call memory accept = acceptSla.callFor(address(verifier));
    vm.prank(NEW_ADMIN);
    vm.expectRevert(CommitteeVerifier.MustBeProposedStorageLocationsAdmin.selector);
    _exec(accept);

    assertEq(verifier.getStorageLocationsAdmin(), address(this), "cancel must not move the role");
  }

  function test_cancelStorageLocationsAdmin_callerMustBeCurrentAdmin() public {
    _exec(transferSla.callFor(address(verifier), NEW_ADMIN));
    BaseScript.Call memory cancel = cancelSla.callFor(address(verifier));

    vm.prank(INTERLOPER);
    vm.expectRevert(CommitteeVerifier.OnlyCallableByStorageLocationsAdmin.selector);
    _exec(cancel);

    assertEq(verifier.getPendingStorageLocationsAdmin(), NEW_ADMIN, "proposal survives an unauthorized cancel");
  }

  // ---- SAFE-mode executor preflight: the generic mechanism is BaseScript's and ----
  // ---- unit-tested in SafeOutput.t.sol; here only the CancelStorageLocations-  ----
  // ---- Admin wrapper, whose role getter is verifier-specific.                  ----

  function test_executorPreflight_acceptsCurrentAdmin() public view {
    cancelSla.requireExecutorIsCurrentAdmin(address(verifier), address(this));
  }

  function test_executorPreflight_rejectsNonAdmin() public {
    vm.expectRevert(
      bytes(
        string.concat(
          "BaseScript: SAFE_ADDRESS ",
          vm.toString(INTERLOPER),
          " is not the current storageLocationsAdmin of ",
          vm.toString(address(verifier)),
          "; the current storageLocationsAdmin is ",
          vm.toString(address(this))
        )
      )
    );
    cancelSla.requireExecutorIsCurrentAdmin(address(verifier), INTERLOPER);
  }

  // ===========================================================================
  //  full ceremony via the per-target scripts
  // ===========================================================================

  /// @dev Each party prepares its own leg: the current holders execute the a- batches,
  ///      the incoming holders their b- batches. All three roles move independently.
  function test_fullHandover_movesEveryRole() public {
    _exec(transferOwner.callFor(address(verifier), NEW_OWNER));
    _exec(transferOwner.callFor(address(resolver), NEW_OWNER));
    _exec(transferSla.callFor(address(verifier), NEW_ADMIN));

    BaseScript.Call memory acceptVerifier = acceptOwner.callFor(address(verifier));
    BaseScript.Call memory acceptResolver = acceptOwner.callFor(address(resolver));
    BaseScript.Call memory acceptSlaCall = acceptSla.callFor(address(verifier));

    vm.prank(NEW_OWNER);
    _exec(acceptVerifier);
    vm.prank(NEW_OWNER);
    _exec(acceptResolver);
    vm.prank(NEW_ADMIN);
    _exec(acceptSlaCall);

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

    // run() asserts chain identity, so the alias has a COMMITTED chain fixture
    // (config/chains/zz-scratch-ownership-factory.json) declaring the test EVM's 31337.
    Types.Deployment memory deployment;
    deployment.aliasName = ALIAS_FACTORY;
    deployment.factory = address(factory);
    deployment.resolver = address(resolver);
    deployment.verifiers = _verifiersOf(address(verifier));
    ConfigLib.writeDeployment(deployment);

    // run() reads OUTPUT_MODE, which deliberately has no default. setEnv is process-global
    // and memoised by forge, but this is the suite's only env-path run() call.
    vm.setEnv("OUTPUT_MODE", "EOA");
    acceptOwner.run(ALIAS_FACTORY, "factory");

    assertEq(factory.owner(), DEFAULT_SENDER, "factory ownership accepted");
  }

  function test_acceptOwnership_run_revertsOnWrongNetwork() public {
    vm.chainId(11155111);
    vm.expectRevert(
      bytes(string.concat("ConfigLib: connected to chain 11155111 but ", ALIAS_FACTORY, " is chain 31337"))
    );
    acceptOwner.run(ALIAS_FACTORY, "factory");
  }

  function test_transferOwnership_callFor_targetsFactory() public view {
    BaseScript.Call memory call = transferOwner.callFor(address(factory), NEW_OWNER);
    assertEq(call.to, address(factory), "addressed to the factory");
    assertEq(call.data, abi.encodeCall(IOwnable.transferOwnership, (NEW_OWNER)), "calldata");
  }

  // ===========================================================================
  //  helpers
  // ===========================================================================

  /// @dev Any test that calls `ConfigLib.writeDeployment` needs its OWN alias. Foundry
  ///      runs test functions concurrently against a shared filesystem, so two tests
  ///      writing `config/deployments/<alias>.json` race: one overwrites the other's
  ///      fixture mid-run and the failure looks like a contract bug, not a test bug.
  ///      `writeDeployment` targets the real config directory, so these must keep the
  ///      zz-scratch- prefix the governance tooling skips.
  string internal constant ALIAS_DISPATCH = "zz-scratch-ownership-dispatch";
  string internal constant ALIAS_REJECT = "zz-scratch-ownership-reject";
  string internal constant ALIAS_FACTORY = "zz-scratch-ownership-factory";

  /// @dev Executes one staged call. NOTE: `vm.prank` applies to the next EXTERNAL call,
  ///      and a `script.callFor(...)` in an argument position is itself external — so
  ///      always hoist the builder into a local BEFORE pranking, then pass it here.
  ///      Getting this wrong silently executes the ceremony as the test contract and the
  ///      assertion fails far from the cause.
  function _exec(
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
