// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CREATE2Factory} from "@chainlink/contracts-ccip/contracts/CREATE2Factory.sol";

/// @title BootstrapFactory
/// @notice Outline step 3. Deploys the CREATE2Factory as the FIRST transaction of
///         a fresh deployer EOA (nonce 0) so the factory lands on the SAME address
///         on every chain. The deployer is placed in the factory allowlist at
///         construction; factory ownership is then transferred to governance.
///
/// @dev EOA-ONLY BY DESIGN. This bootstrap depends on a fresh nonce-0 deployer and
///      MUST NOT be routed through a Safe. The "Safe output on every script" rule
///      (outline step 14) applies to configuration and role-transfer scripts, not
///      to this bootstrap or the initial contract deploys.
///
/// @dev Determinism preconditions (biggest subtle risk with ~8 chains):
///        1. The deployer address has nonce 0 on every target chain.
///        2. Identical compiler settings everywhere (see foundry.toml default profile).
///      Verify the resulting factory address matches across chains before proceeding.
///
/// Usage (EOA / testnet):
///   OUTPUT_MODE=EOA forge script script/deploy/BootstrapFactory.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast --aws   # or --private-key
contract BootstrapFactory is Script {
  function run() external returns (address factory) {
    // The deployer (msg.sender of the broadcast) must be nonce 0 on this chain.
    address deployer = msg.sender;
    require(vm.getNonce(deployer) == 0, "BootstrapFactory: deployer nonce != 0 (address parity broken)");

    // Allowlist the deployer so it can call createAndCall for the resolver deploy.
    address[] memory allowList = new address[](1);
    allowList[0] = deployer;

    vm.broadcast();
    CREATE2Factory f = new CREATE2Factory(allowList);
    factory = address(f);

    console2.log("CREATE2Factory deployed:", factory);
    console2.log("  deployer/allowlisted:", deployer);
    console2.log("  chainid:", block.chainid);

    // TODO(step 3): transfer factory ownership to governance.
    //   - Owner rotation for the factory can be a 2-step transfer if desired.
    //   - Record `factory` into config/deployments/<alias>.json (see _template.json).
    //   - Assert the address equals the factory address on already-deployed chains.
  }
}
