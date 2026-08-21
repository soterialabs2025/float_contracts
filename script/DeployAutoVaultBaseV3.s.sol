// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {V3Deployments8453} from "../contracts/auto-vaults-base-v3/V3Deployments8453.sol";
import {AutoSwapRouterBv3} from "../contracts/auto-vaults-base-v3/AutoSwapRouterBv3.sol";
import {AutoKeeperBv3} from "../contracts/auto-vaults-base-v3/AutoKeeperBv3.sol";
import {AutoFactoryBv3} from "../contracts/auto-vaults-base-v3/AutoFactoryBv3.sol";

/// @notice Deploy Base Uniswap V3 AutoVault Bv3 infra (8453).
/// @dev Reuses AutoOperatorRegistry + SoteriaFeeManager from V3Deployments8453.
contract DeployAutoVaultBaseV3 is Script {
    function run() external {
        uint256 pk = vm.envUint("BASE_DEPOLYER_KEY");
        address deployer = vm.addr(pk);

        address registry = V3Deployments8453.OPERATOR_REGISTRY;
        address feeManager = V3Deployments8453.FEE_MANAGER;

        vm.startBroadcast(pk);

        AutoSwapRouterBv3 swapRouter = new AutoSwapRouterBv3();
        console2.log("AutoSwapRouterBv3", address(swapRouter));

        AutoKeeperBv3 keeper = new AutoKeeperBv3(registry);
        console2.log("AutoKeeperBv3", address(keeper));

        AutoFactoryBv3.InfraConfig memory infra = AutoFactoryBv3.InfraConfig({
            swapRouter: address(swapRouter),
            operatorRegistry: registry,
            keeper: address(keeper),
            feeManager: feeManager
        });
        AutoFactoryBv3 factory = new AutoFactoryBv3(infra);
        console2.log("AutoFactoryBv3", address(factory));

        swapRouter.setStrategyFactory(address(factory));
        keeper.setStrategyFactory(address(factory));

        vm.stopBroadcast();

        console2.log("AutoOperatorRegistry", registry);
        console2.log("feeManager", feeManager);
        console2.log("Deployer", deployer);
        console2.log("WETH", V3Deployments8453.WETH);
    }
}
