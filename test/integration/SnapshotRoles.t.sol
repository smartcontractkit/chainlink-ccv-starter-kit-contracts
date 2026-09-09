// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DriftCheck} from "../../script/governance/DriftCheck.s.sol";
import {SnapshotRoles} from "../../script/governance/SnapshotRoles.s.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";

/// @title SnapshotRolesTest
/// @notice Outline step 16. Verifies the snapshot reads every live role and that what
///         it writes is loadable by `ConfigLib` as a real roles file — the property
///         that makes "review, then copy into config/roles/" a safe promotion path.
contract SnapshotRolesTest is CommitteeVerifierSetup {
  SnapshotRoles internal script;

  string internal constant ALIAS = "snapshot_test_chain";
  address internal constant RESOLVER_FEE_AGGREGATOR = address(0xFEE2);

  function setUp() public virtual override {
    super.setUp();
    script = new SnapshotRoles();
    resolver.setFeeAggregator(RESOLVER_FEE_AGGREGATOR);
  }

  function test_snapshot_readsEveryLiveRole() public view {
    Types.RolesConfig memory roles = script.snapshot(_deployment());

    assertEq(roles.aliasName, ALIAS, "alias carried through");
    assertEq(roles.verifiers.length, 1, "one entry per recorded verifier");
    assertEq(roles.verifiers[0].versionTag, VERSION_TAG, "entry keyed by the recorded tag");
    assertEq(roles.verifiers[0].owner, address(this), "verifier owner");
    assertEq(roles.verifiers[0].storageLocationsAdmin, address(this), "storageLocationsAdmin (constructor: deployer)");
    assertEq(roles.verifiers[0].allowlistAdmin, address(this), "allowlistAdmin from DynamicConfig");
    assertEq(roles.verifiers[0].feeAggregator, FEE_AGGREGATOR, "feeAggregator from DynamicConfig");
    assertEq(roles.resolver.owner, address(this), "resolver owner");
    assertEq(roles.resolver.feeAggregator, RESOLVER_FEE_AGGREGATOR, "resolver feeAggregator");
    assertEq(roles.factoryOwner, address(this), "factory owner");
  }

  /// @dev Every recorded verifier gets its own entry, read from ITS contract.
  function test_snapshot_readsEveryVerifier() public {
    _deploySecondVerifier();
    Types.Deployment memory deployment = _deployment();
    deployment.verifiers = new Types.VerifierDeployment[](2);
    deployment.verifiers[0].versionTag = VERSION_TAG;
    deployment.verifiers[0].addr = address(verifier);
    deployment.verifiers[1].versionTag = VERSION_TAG_V2;
    deployment.verifiers[1].addr = address(verifierV2);
    Types.RolesConfig memory roles = script.snapshot(deployment);
    assertEq(roles.verifiers.length, 2, "one entry per verifier");
    assertEq(roles.verifiers[1].versionTag, VERSION_TAG_V2, "second entry keyed by its tag");
    assertEq(roles.verifiers[1].owner, address(this), "second verifier's owner read from its contract");
  }

  /// @dev The verifier and resolver aggregators are distinct storage on distinct
  ///      contracts; the snapshot must not conflate them.
  function test_snapshot_keepsFeeAggregatorsDistinct() public view {
    Types.RolesConfig memory roles = script.snapshot(_deployment());
    assertTrue(roles.verifiers[0].feeAggregator != roles.resolver.feeAggregator, "aggregators read independently");
  }

  function test_snapshot_absentFactory_leavesOwnerZero() public view {
    Types.Deployment memory deployment = _deployment();
    deployment.factory = address(0);
    assertEq(script.snapshot(deployment).factoryOwner, address(0), "no factory recorded => zero, not a revert");
  }

  /// @dev The promotion path is `cp out/governance/<alias>-<block>.roles.local.json config/roles/<alias>.json`,
  ///      so what we write must parse under the SAME loader that reads config/roles.
  ///      This is the test that would catch a schema drift between the two.
  function test_writeSnapshot_roundTripsThroughConfigLib() public {
    Types.RolesConfig memory snapped = script.snapshot(_deployment());
    string memory path = script.writeSnapshot(ALIAS, snapped);

    Types.RolesConfig memory reloaded = ConfigLib.readRolesByPath(path);

    assertEq(reloaded.aliasName, snapped.aliasName, "alias");
    assertEq(reloaded.verifiers.length, snapped.verifiers.length, "verifier count");
    assertEq(reloaded.verifiers[0].versionTag, snapped.verifiers[0].versionTag, "versionTag");
    assertEq(reloaded.verifiers[0].owner, snapped.verifiers[0].owner, "verifier owner");
    assertEq(
      reloaded.verifiers[0].storageLocationsAdmin, snapped.verifiers[0].storageLocationsAdmin, "storageLocationsAdmin"
    );
    assertEq(reloaded.verifiers[0].allowlistAdmin, snapped.verifiers[0].allowlistAdmin, "allowlistAdmin");
    assertEq(reloaded.verifiers[0].feeAggregator, snapped.verifiers[0].feeAggregator, "verifier feeAggregator");
    assertEq(reloaded.resolver.owner, snapped.resolver.owner, "resolver owner");
    assertEq(reloaded.resolver.feeAggregator, snapped.resolver.feeAggregator, "resolver feeAggregator");
    assertEq(reloaded.factoryOwner, snapped.factoryOwner, "factory owner");
    assertEq(reloaded.factoryAllowlist.length, snapped.factoryAllowlist.length, "allowlist size");
    assertEq(reloaded.factoryAllowlist[0], snapped.factoryAllowlist[0], "allowlisted account");
  }

  /// @dev The two governance scripts must agree on the same role surface: a snapshot
  ///      taken from a chain, promoted as-is, must make `DriftCheck` report clean.
  ///      If one script grows a field the other ignores, this fails.
  function test_snapshotThenDriftCheck_isClean() public {
    Types.RolesConfig memory snapped = script.snapshot(_deployment());
    // A distinct alias per writing test: the snapshot path is alias+block, forge runs
    // tests concurrently against a shared filesystem, and same path == a read/write race.
    string memory path = script.writeSnapshot(string.concat(ALIAS, "-drift"), snapped);
    Types.RolesConfig memory promoted = ConfigLib.readRolesByPath(path);

    DriftCheck drift = new DriftCheck();
    assertEq(drift.checkRoles(_deployment(), promoted), 0, "a fresh snapshot must never drift against its source");
  }

  function _deployment() internal view returns (Types.Deployment memory deployment) {
    deployment.aliasName = ALIAS;
    deployment.factory = address(factory);
    deployment.resolver = address(resolver);
    deployment.verifiers = _verifiersOf(address(verifier));
  }
}
