// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DriftCheck} from "../../script/governance/DriftCheck.s.sol";
import {SnapshotOperator} from "../../script/governance/SnapshotOperator.s.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {FinalityConfigLib} from "../../src/lib/FinalityConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";

/// @title SnapshotOperatorTest
/// @notice Verifies the snapshot reads every live role and verifier setting, and that
///         the file it writes is loadable by `ConfigLib` as a real operator file. That is
///         what makes it safe to review a snapshot and copy it into config/operator/chains/.
contract SnapshotOperatorTest is CommitteeVerifierSetup {
  SnapshotOperator internal script;

  string internal constant ALIAS = "snapshot_test_chain";
  string internal constant STORAGE_LOCATION = "https://aggregator.example/ccv";
  address internal constant RESOLVER_FEE_AGGREGATOR = address(0xFEE2);

  function setUp() public virtual override {
    super.setUp();
    script = new SnapshotOperator();
    resolver.setFeeAggregator(RESOLVER_FEE_AGGREGATOR);
  }

  function test_snapshot_readsEveryLiveRole() public view {
    Types.OperatorConfig memory operator = script.snapshot(_deployment());

    assertEq(operator.aliasName, ALIAS, "alias carried through");
    assertEq(operator.verifiers.length, 1, "one entry per recorded verifier");
    assertEq(operator.verifiers[0].versionTag, VERSION_TAG, "entry keyed by the recorded tag");
    assertEq(operator.verifiers[0].roles.owner, address(this), "verifier owner");
    assertEq(
      operator.verifiers[0].roles.storageLocationsAdmin, address(this), "storageLocationsAdmin (constructor: deployer)"
    );
    assertEq(operator.verifiers[0].roles.allowlistAdmin, address(this), "allowlistAdmin from DynamicConfig");
    assertEq(operator.verifiers[0].roles.feeAggregator, FEE_AGGREGATOR, "feeAggregator from DynamicConfig");
    assertEq(operator.resolver.roles.owner, address(this), "resolver owner");
    assertEq(operator.resolver.roles.feeAggregator, RESOLVER_FEE_AGGREGATOR, "resolver feeAggregator");
    assertEq(operator.factory.roles.owner, address(this), "factory owner");
    assertFalse(operator.verifiers[0].allowedFinality.allowSafeTag, "constructor default: full finality only");
    assertEq(operator.verifiers[0].allowedFinality.minBlockDepth, 0, "constructor default: no depth");
    assertEq(operator.verifiers[0].storageLocations.length, 1, "storage locations read from the verifier");
    assertEq(operator.verifiers[0].storageLocations[0], STORAGE_LOCATION, "storage location content");
  }

  /// @dev Settings are per verifier, read from ITS contract: two live verifiers that
  ///      differ both come back intact rather than one overwriting the other.
  function test_snapshot_verifiersKeepTheirOwnSettings() public {
    _deploySecondVerifier();
    string[] memory elsewhere = new string[](1);
    elsewhere[0] = "https://elsewhere.example/ccv";
    verifierV2.updateStorageLocations(elsewhere);
    Types.Deployment memory deployment = _deployment();
    deployment.verifiers = new Types.VerifierDeployment[](2);
    deployment.verifiers[0].versionTag = VERSION_TAG;
    deployment.verifiers[0].addr = address(verifier);
    deployment.verifiers[1].versionTag = VERSION_TAG_V2;
    deployment.verifiers[1].addr = address(verifierV2);
    Types.OperatorConfig memory operator = script.snapshot(deployment);
    assertEq(operator.verifiers[0].storageLocations[0], STORAGE_LOCATION, "first verifier's own list");
    assertEq(operator.verifiers[1].storageLocations[0], "https://elsewhere.example/ccv", "second verifier's own list");
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
    Types.OperatorConfig memory operator = script.snapshot(deployment);
    assertEq(operator.verifiers.length, 2, "one entry per verifier");
    assertEq(operator.verifiers[1].versionTag, VERSION_TAG_V2, "second entry keyed by its tag");
    assertEq(operator.verifiers[1].roles.owner, address(this), "second verifier's owner read from its contract");
  }

  /// @dev The verifier and resolver aggregators are distinct storage on distinct
  ///      contracts; the snapshot must not conflate them.
  function test_snapshot_keepsFeeAggregatorsDistinct() public view {
    Types.OperatorConfig memory operator = script.snapshot(_deployment());
    assertTrue(
      operator.verifiers[0].roles.feeAggregator != operator.resolver.roles.feeAggregator,
      "aggregators read independently"
    );
  }

  function test_snapshot_absentFactory_leavesOwnerZero() public view {
    Types.Deployment memory deployment = _deployment();
    deployment.factory = address(0);
    assertEq(script.snapshot(deployment).factory.roles.owner, address(0), "no factory recorded => zero, not a revert");
  }

  /// @dev The promotion path is `cp out/governance/<alias>-<block>.operator.local.json config/operator/chains/<alias>.json`,
  ///      so what we write must parse under the SAME loader that reads config/operator/chains/.
  ///      This is the test that would catch a schema drift between the two.
  function test_writeSnapshot_roundTripsThroughConfigLib() public {
    Types.OperatorConfig memory snapped = script.snapshot(_deployment());
    // The committee is carried over by run(), not read from chain; the writer must still emit it.
    snapped.verifiers[0].signatureConfig.threshold = 3;
    snapped.verifiers[0].signatureConfig.signers = new address[](4);
    for (uint160 i = 0; i < 4; ++i) {
      snapped.verifiers[0].signatureConfig.signers[i] = address(0xA0 + i);
    }
    string memory path = script.writeSnapshot(ALIAS, snapped);

    Types.OperatorConfig memory reloaded = ConfigLib.readOperatorByPath(path);

    assertEq(reloaded.aliasName, snapped.aliasName, "alias");
    assertEq(reloaded.verifiers.length, snapped.verifiers.length, "verifier count");
    assertEq(reloaded.verifiers[0].versionTag, snapped.verifiers[0].versionTag, "versionTag");
    assertEq(reloaded.verifiers[0].roles.owner, snapped.verifiers[0].roles.owner, "verifier owner");
    assertEq(
      reloaded.verifiers[0].roles.storageLocationsAdmin,
      snapped.verifiers[0].roles.storageLocationsAdmin,
      "storageLocationsAdmin"
    );
    assertEq(reloaded.verifiers[0].roles.allowlistAdmin, snapped.verifiers[0].roles.allowlistAdmin, "allowlistAdmin");
    assertEq(
      reloaded.verifiers[0].roles.feeAggregator, snapped.verifiers[0].roles.feeAggregator, "verifier feeAggregator"
    );
    assertEq(reloaded.resolver.roles.owner, snapped.resolver.roles.owner, "resolver owner");
    assertEq(reloaded.resolver.roles.feeAggregator, snapped.resolver.roles.feeAggregator, "resolver feeAggregator");
    assertEq(reloaded.factory.roles.owner, snapped.factory.roles.owner, "factory owner");
    assertEq(reloaded.factory.roles.allowlist.length, snapped.factory.roles.allowlist.length, "allowlist size");
    assertEq(reloaded.factory.roles.allowlist[0], snapped.factory.roles.allowlist[0], "allowlisted account");
    assertEq(
      reloaded.verifiers[0].storageLocations.length, snapped.verifiers[0].storageLocations.length, "location count"
    );
    assertEq(reloaded.verifiers[0].storageLocations[0], snapped.verifiers[0].storageLocations[0], "storage location");
    assertEq(reloaded.verifiers[0].allowedFinality.allowSafeTag, false, "allowSafeTag");
    assertEq(reloaded.verifiers[0].allowedFinality.minBlockDepth, 0, "minBlockDepth");
    assertEq(reloaded.verifiers[0].signatureConfig.threshold, 3, "committee threshold");
    assertEq(reloaded.verifiers[0].signatureConfig.signers.length, 4, "committee size");
    assertEq(reloaded.verifiers[0].signatureConfig.signers[3], address(0xA3), "committee member");
  }

  /// @dev A populated finality block must survive the write: the loader rejects a literal
  ///      zero depth, so the writer must omit absent fields rather than write zeros.
  function test_writeSnapshot_roundTripsAllowedFinality() public {
    verifier.setAllowedFinalityConfig(
      FinalityConfigLib.encode(Types.AllowedFinality({allowSafeTag: true, minBlockDepth: 7}))
    );
    Types.OperatorConfig memory snapped = script.snapshot(_deployment());
    string memory path = script.writeSnapshot(string.concat(ALIAS, "-finality"), snapped);
    Types.OperatorConfig memory reloaded = ConfigLib.readOperatorByPath(path);
    assertTrue(reloaded.verifiers[0].allowedFinality.allowSafeTag, "safe tag round-trips");
    assertEq(reloaded.verifiers[0].allowedFinality.minBlockDepth, 7, "depth round-trips");
  }

  /// @dev The two governance scripts must agree on the same role surface: a snapshot
  ///      taken from a chain, promoted as-is, must make `DriftCheck` report clean.
  ///      If one script grows a field the other ignores, this fails.
  function test_snapshotThenDriftCheck_isClean() public {
    Types.OperatorConfig memory snapped = script.snapshot(_deployment());
    // A distinct alias per writing test: the snapshot path is alias+block, forge runs
    // tests concurrently against a shared filesystem, and same path == a read/write race.
    string memory path = script.writeSnapshot(string.concat(ALIAS, "-drift"), snapped);
    Types.OperatorConfig memory promoted = ConfigLib.readOperatorByPath(path);

    DriftCheck drift = new DriftCheck();
    assertEq(drift.checkRoles(_deployment(), promoted), 0, "a fresh snapshot must never drift against its source");
    assertEq(drift.checkVerifierConfig(_deployment(), promoted), 0, "verifier settings agree too");
  }

  function _deployment() internal view returns (Types.Deployment memory deployment) {
    deployment.aliasName = ALIAS;
    deployment.factory = address(factory);
    deployment.resolver = address(resolver);
    deployment.verifiers = _verifiersOf(address(verifier));
  }
}
