// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CREATE2Factory} from "@chainlink/contracts-ccip/contracts/CREATE2Factory.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployResolver
/// @notice Deploys the VersionedVerifierResolver via CREATE2 with a
///         FIXED salt so it gets the SAME address on every chain, and hands ownership
///         to the CONFIGURED resolver owner (config/roles/<alias>.json `resolver.owner`).
///
/// @dev The resolver has NO constructor arguments, so its CREATE2 initcode is just the
///      creation bytecode: nothing per-chain can perturb the address (only the salt +
///      compiler settings). Keep `resolverSalt` identical across chains and deploy with
///      the default (release) profile so the bytecode matches everywhere.
///
/// @dev Ownership. The factory (the deployer) is the resolver's initial owner. We use
///      createAndTransferOwnership to PROPOSE ownership to the configured owner:
///        - configured owner == deployer: the script accepts in-place, so the deployer
///          owns it and can run the resolver config scripts directly (EOA / testing).
///        - configured owner is another EOA / a Safe: it must call acceptOwnership()
///          before configuring (via script/ownership/AcceptOwnership or the b- handover
///          batch). Until then the factory remains the owner.
///
/// Usage:
///   OUTPUT_MODE=EOA forge script script/deploy/DeployResolver.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
contract DeployResolver is Script {
  function run(
    string calldata chainAlias
  ) external returns (address resolver) {
    // CREATE2 makes a wrong-chain deploy succeed at the expected address, so verify first.
    Types.ChainConfig memory chainConfig = ConfigLib.readChain(chainAlias);
    ConfigLib.assertChainMatches(chainConfig, chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeploymentOrEmpty(chainAlias);

    require(deployment.factory != address(0), "DeployResolver: factory not recorded; run BootstrapFactory first");
    address configuredOwner = roles.resolver.owner;
    require(configuredOwner != address(0), "DeployResolver: resolver.owner role unset");

    address deployer = msg.sender;
    bytes memory creationCode = type(VersionedVerifierResolver).creationCode;

    // Precompute the address so parity can be asserted after deployment.
    address predicted = CREATE2Factory(deployment.factory).computeAddress(creationCode, chainConfig.resolverSalt);
    console2.log("[DeployResolver] chain:", chainAlias);
    console2.log("  factory:", deployment.factory);
    console2.log("  predicted resolver:", predicted);

    // Deploy via CREATE2 and propose ownership to the configured owner.
    vm.broadcast();
    resolver = CREATE2Factory(deployment.factory)
      .createAndTransferOwnership(creationCode, chainConfig.resolverSalt, configuredOwner);
    require(resolver == predicted, "DeployResolver: deployed address != predicted (determinism broken)");
    console2.log("  resolver deployed:", resolver);

    if (configuredOwner == deployer) {
      // Deployer is the configured owner: accept now so it is immediately usable.
      vm.broadcast();
      VersionedVerifierResolver(resolver).acceptOwnership();
      console2.log("  owner: deployer (accepted in-place)");
    } else {
      console2.log("  owner PROPOSED to configured resolver.owner:", configuredOwner);
      console2.log("  (that owner must acceptOwnership() before running resolver config scripts)");
    }

    deployment.resolver = resolver;
    ConfigLib.writeDeployment(deployment);
    console2.log("  recorded ->", ConfigLib.deploymentPath(chainAlias));
    console2.log("  ACTION: confirm this matches the resolver address on other chains.");
  }
}
