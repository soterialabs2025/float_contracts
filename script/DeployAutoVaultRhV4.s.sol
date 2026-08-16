// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {AutoOperatorRegistry} from "../contracts/auto-vault-rh-v4/AutoOperatorRegistry.sol";
import {AutoSwapRouter} from "../contracts/auto-vault-rh-v4/AutoSwapRouter.sol";
import {AutoKeeper} from "../contracts/auto-vault-rh-v4/AutoKeeper.sol";
import {AutoFactoryV2} from "../contracts/auto-vault-rh-v4/AutoFactoryV2.sol";

/// @notice Deploy RH AutoVault V4 infra on Robinhood (4663).
/// @dev Reuses existing operator registry + feeManager from ADDRESSES_2 when set via env;
///      otherwise deploys a fresh registry with the broadcaster as initial operator.
contract DeployAutoVaultRhV4 is Script {
    address constant EXISTING_REGISTRY = 0x7df1120a04D82eA92EA2d5AA005e3316B37b936E;
    address constant EXISTING_FEE_MANAGER = 0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_WALLET_KEY");
        address deployer = vm.addr(pk);

        bool freshRegistry = vm.envOr("RH_V4_FRESH_REGISTRY", false);
        address registry = freshRegistry ? address(0) : EXISTING_REGISTRY;
        address feeManager = vm.envOr("RH_V4_FEE_MANAGER", EXISTING_FEE_MANAGER);

        vm.startBroadcast(pk);

        if (registry == address(0)) {
            registry = address(new AutoOperatorRegistry(deployer));
            console2.log("AutoOperatorRegistry", registry);
        } else {
            console2.log("Reusing AutoOperatorRegistry", registry);
        }

        AutoSwapRouter swapRouter = new AutoSwapRouter();
        console2.log("AutoSwapRouter", address(swapRouter));

        AutoKeeper keeper = new AutoKeeper(registry);
        console2.log("AutoKeeper", address(keeper));

        AutoFactoryV2.InfraConfig memory infra = AutoFactoryV2.InfraConfig({
            swapRouter: address(swapRouter),
            operatorRegistry: registry,
            keeper: address(keeper),
            feeManager: feeManager
        });
        AutoFactoryV2 factory = new AutoFactoryV2(infra);
        console2.log("AutoFactoryV2", address(factory));
        console2.log("feeManager", feeManager);

        swapRouter.setStrategyFactory(address(factory));
        keeper.setStrategyFactory(address(factory));

        vm.stopBroadcast();

        console2.log("Deployer", deployer);
        console2.log("Infra ready: call deployVaultPackage(asset, PoolKey, hookData) with ASSET/aeWETH key");
    }
}
