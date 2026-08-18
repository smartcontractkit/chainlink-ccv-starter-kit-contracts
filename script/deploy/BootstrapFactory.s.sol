// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CREATE2Factory} from "@chainlink/contracts-ccip/contracts/CREATE2Factory.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";

/// @title BootstrapFactory
/// @notice Deploys the CREATE2Factory as the FIRST transaction of a
///         fresh deployer EOA (nonce 0) so the factory lands on the SAME address on
///         every chain. The deployer is placed in the factory allowlist at
///         construction. Ownership is set to the CONFIGURED factory owner
///         (config/roles/<alias>.json `factory.owner`). The factory address is
///         recorded into config/deployments/<alias>.json.
///
/// @dev EOA-ONLY BY DESIGN. The bootstrap depends on a fresh nonce-0 deployer and MUST
///      NOT be routed through a Safe. The "Safe output on every script" rule (step 14)
///      applies to configuration and role-transfer scripts, not this bootstrap.
///
/// @dev Determinism preconditions (the biggest subtle risk at ~8 chains):
///        1. The deployer has nonce 0 on every target chain.
///        2. Identical compiler settings everywhere (foundry.toml default profile).
///      Verify the resulting factory address matches across chains before proceeding.
///
/// @dev Ownership (CREATE2Factory is Ownable2Step). The deployer is the owner at
///      construction; this script then hands it to the configured owner:
///        - configured owner == deployer (or unset): keep the deployer as owner.
///        - configured owner is another EOA / a Safe: PROPOSE the transfer; that owner
///          calls acceptOwnership() to complete (out of band / via a Safe batch).
///      The deployer stays allowlisted either way, so the resolver deploy still works.
///
/// Usage:
///   OUTPUT_MODE=EOA forge script script/deploy/BootstrapFactory.s.sol \
///     --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
contract BootstrapFactory is Script {
  function run(string calldata chainAlias) external returns (address factory) {
    address deployer = msg.sender;
    require(vm.getNonce(deployer) == 0, "BootstrapFactory: deployer nonce != 0 (address parity broken)");

    // Allowlist the deployer so it can call createAndCall for the resolver deploy.
    address[] memory allowList = new address[](1);
    allowList[0] = deployer;

    vm.broadcast();
    CREATE2Factory f = new CREATE2Factory(allowList);
    factory = address(f);

    console2.log("[BootstrapFactory] chain:", chainAlias);
    console2.log("  CREATE2Factory:", factory);
    console2.log("  deployer/allowlisted:", deployer);

    // Hand ownership to the configured factory owner (roles-as-data). Unset (zero)
    // means "keep the deployer as owner".
    address configuredOwner = ConfigLib.readRolesOrEmpty(chainAlias).factoryOwner;
    if (configuredOwner == address(0) || configuredOwner == deployer) {
      console2.log("  owner: deployer (configured factory.owner unset or == deployer)");
    } else {
      vm.broadcast();
      f.transferOwnership(configuredOwner);
      console2.log("  owner PROPOSED to configured factory.owner:", configuredOwner);
      console2.log("  (that owner must call acceptOwnership() to complete the 2-step transfer)");
    }

    // Record the factory address (merges into any existing deployment record).
    Types.Deployment memory dep = ConfigLib.readDeploymentOrEmpty(chainAlias);
    dep.factory = factory;
    ConfigLib.writeDeployment(dep);
    console2.log("  recorded ->", ConfigLib.deploymentPath(chainAlias));
  }
}