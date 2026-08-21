// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {V4Deployments8453} from "../contracts/v4/V4Deployments8453.sol";
import {AutoSwapRouterBv4} from "../contracts/auto-vault-base-v4/AutoSwapRouterBv4.sol";
import {AutoKeeperBv4} from "../contracts/auto-vault-base-v4/AutoKeeperBv4.sol";
import {AutoFactoryBv4} from "../contracts/auto-vault-base-v4/AutoFactoryBv4.sol";

/// @notice Deploy Base Uniswap V4 AutoVault Bv4 infra (8453) with ShareStaking.
/// @dev Reuses AutoOperatorRegistry + SoteriaFeeManager from ADDRESSES_2.md.
contract DeployAutoVaultBaseV4 is Script {
    address constant EXISTING_REGISTRY = 0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8;
    address constant EXISTING_FEE_MANAGER = 0x9f6e579117BeAd116E25CfeC43e319637DE0bCEe;

    function run() external {
        uint256 pk = vm.envUint("BASE_DEPOLYER_KEY");
        address deployer = vm.addr(pk);

        address registry = EXISTING_REGISTRY;
        address feeManager = EXISTING_FEE_MANAGER;

        vm.startBroadcast(pk);

        AutoSwapRouterBv4 swapRouter = new AutoSwapRouterBv4();
        console2.log("AutoSwapRouterBv4", address(swapRouter));

        AutoKeeperBv4 keeper = new AutoKeeperBv4(registry);
        console2.log("AutoKeeperBv4", address(keeper));

        AutoFactoryBv4.InfraConfig memory infra = AutoFactoryBv4.InfraConfig({
            swapRouter: address(swapRouter),
            operatorRegistry: registry,
            keeper: address(keeper),
            feeManager: feeManager
        });
        AutoFactoryBv4 factory = new AutoFactoryBv4(infra);
        console2.log("AutoFactoryBv4", address(factory));

        swapRouter.setStrategyFactory(address(factory));
        keeper.setStrategyFactory(address(factory));

        vm.stopBroadcast();

        console2.log("AutoOperatorRegistry", registry);
        console2.log("feeManager", feeManager);
        console2.log("Deployer", deployer);
        console2.log("WETH", V4Deployments8453.WETH);
        console2.log("Infra ready: call deployVaultPackage(asset, PoolKey, hookData) with ASSET/WETH key");
    }
}
