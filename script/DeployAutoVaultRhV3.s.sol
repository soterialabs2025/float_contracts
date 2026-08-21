// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {AutoSwapRouterRhV3} from "../contracts/auto-vaults-rh-v3/AutoSwapRouterRhV3.sol";
import {AutoKeeperRhV3} from "../contracts/auto-vaults-rh-v3/AutoKeeperRhV3.sol";
import {AutoFactoryRhV3} from "../contracts/auto-vaults-rh-v3/AutoFactoryRhV3.sol";

/// @notice Deploy RH AutoVault RhV3 infra on Robinhood (4663).
/// @dev Reuses AutoOperatorRegistry + SoteriaFeeManagerRh from ADDRESSES_2.
contract DeployAutoVaultRhV3 is Script {
    address constant EXISTING_REGISTRY = 0x7df1120a04D82eA92EA2d5AA005e3316B37b936E;
    address constant EXISTING_FEE_MANAGER = 0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE;
    address constant AE_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    function run() external {
        uint256 pk = vm.envUint("RH_DEPLOYER_KEY");
        address deployer = vm.addr(pk);

        address registry = EXISTING_REGISTRY;
        address feeManager = EXISTING_FEE_MANAGER;

        vm.startBroadcast(pk);

        AutoSwapRouterRhV3 swapRouter = new AutoSwapRouterRhV3();
        console2.log("AutoSwapRouterRhV3", address(swapRouter));

        AutoKeeperRhV3 keeper = new AutoKeeperRhV3(registry);
        console2.log("AutoKeeperRhV3", address(keeper));

        AutoFactoryRhV3.InfraConfig memory infra = AutoFactoryRhV3.InfraConfig({
            swapRouter: address(swapRouter),
            operatorRegistry: registry,
            keeper: address(keeper),
            feeManager: feeManager
        });
        AutoFactoryRhV3 factory = new AutoFactoryRhV3(infra);
        console2.log("AutoFactoryRhV3", address(factory));

        swapRouter.setStrategyFactory(address(factory));
        keeper.setStrategyFactory(address(factory));

        vm.stopBroadcast();

        console2.log("AutoOperatorRegistry", registry);
        console2.log("feeManager", feeManager);
        console2.log("Deployer", deployer);
        console2.log("aeWETH", AE_WETH);
        console2.log("Infra ready: call deployVaultPackage(asset, poolFee) with ASSET/aeWETH pool");
    }
}
