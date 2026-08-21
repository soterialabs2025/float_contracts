// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {SushiV3Deployments4663} from "../contracts/auto-vaults-rh-sushi-v3/SushiV3Deployments4663.sol";
import {AutoSwapRouterSv3} from "../contracts/auto-vaults-rh-sushi-v3/AutoSwapRouterSv3.sol";
import {AutoKeeperSv3} from "../contracts/auto-vaults-rh-sushi-v3/AutoKeeperSv3.sol";
import {AutoFactorySv3} from "../contracts/auto-vaults-rh-sushi-v3/AutoFactorySv3.sol";

/// @notice Deploy RH AutoVault Sushi Sv3 infra on Robinhood (4663).
/// @dev Reuses shared RH AutoOperatorRegistry + SoteriaFeeManagerRh; new Sv3 router/keeper/factory.
contract DeployAutoVaultRhSushiV3 is Script {
    address constant EXISTING_REGISTRY = 0x7df1120a04D82eA92EA2d5AA005e3316B37b936E;
    address constant EXISTING_FEE_MANAGER = 0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE;

    function run() external {
        uint256 pk = vm.envUint("RH_DEPLOYER_KEY");
        address deployer = vm.addr(pk);

        address registry = EXISTING_REGISTRY;
        address feeManager = EXISTING_FEE_MANAGER;

        vm.startBroadcast(pk);

        AutoSwapRouterSv3 swapRouter = new AutoSwapRouterSv3();
        console2.log("AutoSwapRouterSv3", address(swapRouter));

        AutoKeeperSv3 keeper = new AutoKeeperSv3(registry);
        console2.log("AutoKeeperSv3", address(keeper));

        AutoFactorySv3.InfraConfig memory infra = AutoFactorySv3.InfraConfig({
            swapRouter: address(swapRouter),
            operatorRegistry: registry,
            keeper: address(keeper),
            feeManager: feeManager
        });
        AutoFactorySv3 factory = new AutoFactorySv3(infra);
        console2.log("AutoFactorySv3", address(factory));

        swapRouter.setStrategyFactory(address(factory));
        keeper.setStrategyFactory(address(factory));

        vm.stopBroadcast();

        console2.log("AutoOperatorRegistry", registry);
        console2.log("feeManager", feeManager);
        console2.log("Deployer", deployer);
        console2.log("aeWETH", SushiV3Deployments4663.WETH);
        console2.log("Sushi factory", SushiV3Deployments4663.FACTORY);
        console2.log("Infra ready: call deployVaultPackage(asset, poolFee) with ASSET/aeWETH sushi pool");
    }
}
