// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Factory} from "../src/Factory.sol";
import {Router} from "../src/Router.sol";

/// @title Deploy
/// @notice Deploys the Factory (constant-product pair factory) and the Router.
/// @dev    Reads the fee-to-setter from the FEE_TO_SETTER env var, defaulting to the
///         broadcasting deployer. Pairs are created afterwards via factory.createPair.
contract Deploy is Script {
    function run() external returns (Factory factory, Router router) {
        address feeToSetter = vm.envOr("FEE_TO_SETTER", msg.sender);

        vm.startBroadcast();

        factory = new Factory(feeToSetter);
        router = new Router(address(factory));

        vm.stopBroadcast();

        console2.log("Factory deployed at:", address(factory));
        console2.log("Router  deployed at:", address(router));
    }
}
