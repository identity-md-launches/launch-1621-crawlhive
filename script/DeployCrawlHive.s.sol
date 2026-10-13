// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {CrawlHiveToken} from "../src/CrawlHiveToken.sol";

/// @title DeployCrawlHive
/// @notice Local / testnet deployment helper. The IdentityMD launch does NOT use this script: the
///         factory deploys the token from its creation code and becomes the deployer. This exists so
///         a reviewer can reproduce a deployment on a fork or a testnet with their own key.
/// @dev The token has no configuration: `deploy()` takes no arguments and reads no environment, so
///      tests call it directly. `run()` only wraps it in a broadcast.
contract DeployCrawlHive is Script {
    /// @notice Deploys the token; the caller becomes the deployer and receives the whole supply.
    function deploy() public returns (CrawlHiveToken token) {
        token = new CrawlHiveToken();
    }

    /// @notice Broadcast entry point: `forge script script/DeployCrawlHive.s.sol --broadcast`.
    function run() external returns (CrawlHiveToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
