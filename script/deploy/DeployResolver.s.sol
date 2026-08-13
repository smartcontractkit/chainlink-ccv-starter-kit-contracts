// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CREATE2Factory} from "@chainlink/contracts-ccip/contracts/CREATE2Factory.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";

/// @title DeployResolver
/// @notice Outline step 4. Deploys the VersionedVerifierResolver via CREATE2 with a
///         FIXED salt so it gets the SAME address on every chain.
///
/// @dev The resolver has no constructor arguments, so its CREATE2 initcode is just
///      the creation bytecode — nothing per-chain can perturb the address (only the
///      salt and compiler settings matter). Keep `resolverSalt` identical across
///      chains (config/chains/<alias>.json) and deploy with the default (release)
///      profile so bytecode matches everywhere.
///
/// @dev Because the factory is the deployer, the factory is the resolver's initial
///      owner. We use `createAndTransferOwnership` so ownership is handed to the
///      intended holder immediately; that holder later calls `acceptOwnership()`
///      (2-step). See script/ownership/.
///
/// @dev EOA path (the deployer must be factory-allowlisted — see BootstrapFactory).
///
/// Usage:
///   OUTPUT_MODE=EOA forge script script/deploy/DeployResolver.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
contract DeployResolver is Script {
  function run(string calldata chainAlias) external returns (address resolver) {
    Types.ChainConfig memory cc = ConfigLib.readChain(chainAlias);
    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    Types.RolesConfig memory roles = ConfigLib.readRoles(chainAlias);

    require(dep.factory != address(0), "DeployResolver: factory not recorded for chain");

    // Predict the address so we can assert cross-chain parity BEFORE deploying.
    bytes memory creationCode = type(VersionedVerifierResolver).creationCode;
    address predicted = CREATE2Factory(dep.factory).computeAddress(creationCode, cc.resolverSalt);
    console2.log("Predicted resolver address:", predicted);

    // The resolver owner should ultimately be governance (roles.resolver.owner).
    address initialOwner = roles.resolver.owner;
    require(initialOwner != address(0), "DeployResolver: resolver owner role unset");

    vm.broadcast();
    resolver = CREATE2Factory(dep.factory).createAndTransferOwnership(creationCode, cc.resolverSalt, initialOwner);

    require(resolver == predicted, "DeployResolver: deployed address != predicted");
    console2.log("Resolver deployed:", resolver);

    // TODO(step 4): record `resolver` into config/deployments/<alias>.json.
    // TODO: assert `resolver` equals the resolver address on already-deployed chains
    //       (the same-address-everywhere guarantee). A mismatch is silent otherwise.
    // NOTE: fee aggregator + implementation wiring happen in the configure/ scripts,
    //       and the new owner must call acceptOwnership() (script/ownership/).
  }
}
