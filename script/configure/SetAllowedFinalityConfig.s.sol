// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";

/// @title SetAllowedFinalityConfig
/// @notice Outline step 9. Sets the allowed finality config (bytes4, FinalityCodec
///         encoding — NOT a plain block depth). Per verifier / per chain.
/// @dev Target call (grounded): CommitteeVerifier.setAllowedFinalityConfig(bytes4).
///      onlyOwner.
/// @dev The finality value is a per-chain input; add a `finalityConfig` field to
///      config/chains/<alias>.json when the FinalityCodec value is decided.
contract SetAllowedFinalityConfig is BaseScript {
  bytes4 internal constant SELECTOR = CommitteeVerifier.setAllowedFinalityConfig.selector;

  function run(string calldata chainAlias) external {
    _initOutput();

    Types.Deployment memory dep = ConfigLib.readDeployment(chainAlias);
    console2.log("[SetAllowedFinalityConfig] chain:", chainAlias);
    console2.log("  target verifier:", dep.verifier);

    // TODO(step 9): read the FinalityCodec-encoded bytes4 from config and:
    //   _stage(dep.verifier, abi.encodeCall(CommitteeVerifier.setAllowedFinalityConfig, (finality)));

    _flush("set-allowed-finality-config");
  }
}
