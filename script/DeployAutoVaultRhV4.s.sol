// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {AutoOperatorRegistryRhV4} from "../contracts/auto-vault-rh-v4/AutoOperatorRegistryRhV4.sol";
import {AutoSwapRouterRhV4} from "../contracts/auto-vault-rh-v4/AutoSwapRouterRhV4.sol";
import {AutoKeeperRhV4} from "../contracts/auto-vault-rh-v4/AutoKeeperRhV4.sol";
import {AutoFactoryRhV4} from "../contracts/auto-vault-rh-v4/AutoFactoryRhV4.sol";

/// @notice Deploy RH AutoVault RhV4 infra on Robinhood (4663).
/// @dev Reuses existing operator registry + feeManager from ADDRESSES_2 when set via env;
///      otherwise deploys a fresh registry with the broadcaster as initial operator.
contract DeployAutoVaultRhV4 is Script {
    address constant EXISTING_REGISTRY = 0x7df1120a04D82eA92EA2d5AA005e3316B37b936E;
    address constant EXISTING_FEE_MANAGER = 0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE;

    function run() external {
        uint256 pk = vm.envUint("RH_DEPLOYER_KEY");
        address deployer = vm.addr(pk);

        bool freshRegistry = vm.envOr("RH_V4_FRESH_REGISTRY", false);
        address registry = freshRegistry ? address(0) : EXISTING_REGISTRY;
        address feeManager = vm.envOr("RH_V4_FEE_MANAGER", EXISTING_FEE_MANAGER);

        vm.startBroadcast(pk);

        if (registry == address(0)) {
            registry = address(new AutoOperatorRegistryRhV4(deployer));
            console2.log("AutoOperatorRegistryRhV4", registry);
        } else {
            console2.log("Reusing AutoOperatorRegistry", registry);
        }

        AutoSwapRouterRhV4 swapRouter = new AutoSwapRouterRhV4();
        console2.log("AutoSwapRouterRhV4", address(swapRouter));

        AutoKeeperRhV4 keeper = new AutoKeeperRhV4(registry);
        console2.log("AutoKeeperRhV4", address(keeper));

        AutoFactoryRhV4.InfraConfig memory infra = AutoFactoryRhV4.InfraConfig({
            swapRouter: address(swapRouter),
            operatorRegistry: registry,
            keeper: address(keeper),
            feeManager: feeManager
        });
        AutoFactoryRhV4 factory = new AutoFactoryRhV4(infra);
        console2.log("AutoFactoryRhV4", address(factory));
        console2.log("feeManager", feeManager);

        swapRouter.setStrategyFactory(address(factory));
        keeper.setStrategyFactory(address(factory));

        vm.stopBroadcast();

        console2.log("Deployer", deployer);
        console2.log(
            "Infra ready: deployVaultPackage(asset, PoolKey, hookData, BandConfig{rangeBelow,rangeAbove,innerBelow,innerAbove})"
        );
        console2.log("Band widths must be positive multiples of PoolKey.tickSpacing");
        console2.log("PoolKey: token/ETH, currency0=address(0), currency1=asset");
    }
}
