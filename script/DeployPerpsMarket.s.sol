// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console2} from "lib/forge-std/src/Script.sol";
import {PerpsMarket} from "../src/PerpsMarket.sol";

contract DeployPerpsMarket is Script {
    function run() external {

        // deployer
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.createSelectFork("arbitrum-sepolia");

        vm.startBroadcast(deployerPrivateKey);

        // deploy read contract
        PerpsMarket perpsMarket = new L1Read();
        console2.log("PerpsMarket contract deployed to: ", address(perpsMarket));

        vm.stopBroadcast();
    }
}