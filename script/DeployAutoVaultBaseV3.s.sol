// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {V3Deployments8453} from "../contracts/auto-vaults-base-v3/V3Deployments8453.sol";
import {AutoSwapRouterV3} from "../contracts/auto-vaults-base-v3/AutoSwapRouterV3.sol";
import {AutoKeeper} from "../contracts/auto-vaults-base-v3/AutoKeeper.sol";
import {AutoFactoryV3} from "../contracts/auto-vaults-base-v3/AutoFactoryV3.sol";

/// @notice Deploy Base Uniswap V3 AutoVault infra (8453).
/// @dev Reuses AutoOperatorRegistry + SoteriaFeeManager from V3Deployments8453.
contract DeployAutoVaultBaseV3 is Script {
    function run() external {
        uint256 pk = vm.envUint("BASE_DEPOLYER_KEY");
        address deployer = vm.addr(pk);

        address registry = V3Deployments8453.OPERATOR_REGISTRY;
        address feeManager = V3Deployments8453.FEE_MANAGER;

        vm.startBroadcast(pk);

        AutoSwapRouterV3 swapRouter = new AutoSwapRouterV3();
        console2.log("AutoSwapRouterV3", address(swapRouter));

        AutoKeeper keeper = new AutoKeeper(registry);
        console2.log("AutoKeeper", address(keeper));

        AutoFactoryV3.InfraConfig memory infra = AutoFactoryV3.InfraConfig({
            swapRouter: address(swapRouter),
            operatorRegistry: registry,
            keeper: address(keeper),
            feeManager: feeManager
        });
        AutoFactoryV3 factory = new AutoFactoryV3(infra);
        console2.log("AutoFactoryV3", address(factory));

        swapRouter.setStrategyFactory(address(factory));
        keeper.setStrategyFactory(address(factory));

        vm.stopBroadcast();

        console2.log("AutoOperatorRegistry", registry);
        console2.log("feeManager", feeManager);
        console2.log("Deployer", deployer);
        console2.log("WETH", V3Deployments8453.WETH);
    }
}
