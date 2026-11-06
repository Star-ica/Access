// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../Access.sol";

/**
 * @title Deploy Access
 * @notice Foundry deployment script for BOT Chain
 *
 * Usage:
 *   forge script script/Deploy.s.sol \
 *     --rpc-url $BOT_CHAIN_RPC \
 *     --private-key $DEPLOYER_PRIVATE_KEY \
 *     --broadcast
 *
 * Environment variables:
 *   BOT_CHAIN_RPC        — BOT Chain RPC endpoint
 *   DEPLOYER_PRIVATE_KEY — deployer wallet private key
 *   TREASURY_ADDRESS     — address that receives platform fees
 */
contract DeployAccess is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address treasury    = vm.envOr("TREASURY_ADDRESS", deployer); // defaults to deployer if not set

        console.log("Deploying Access");
        console.log("Deployer :", deployer);
        console.log("Treasury :", treasury);
        console.log("Chain ID :", block.chainid);

        vm.startBroadcast(deployerKey);
        Access access = new Access(treasury);
        vm.stopBroadcast();

        console.log("Access deployed at:", address(access));
        console.log("Platform fee     :", access.PLATFORM_FEE_BPS(), "bps (2%)");
        console.log("");
        console.log("Next steps:");
        console.log("1. Update CFG.CONTRACT_ADDRESS in index.html");
        console.log("2. Update CFG.CHAIN_ID and CFG.RPC_URL for BOT Chain");
        console.log("3. Register your first organization via registerOrg()");
    }
}
