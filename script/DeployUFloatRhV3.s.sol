// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {V3Deployments4663} from "../contracts/ustrategy-rh-v3/V3Deployments4663.sol";
import {UFloatSwapRouterV3} from "../contracts/ustrategy-rh-v3/UFloatSwapRouterV3.sol";
import {UFloatKeeperV3} from "../contracts/ustrategy-rh-v3/UFloatKeeperV3.sol";
import {UFloatStrategyFactoryV3} from "../contracts/ustrategy-rh-v3/UFloatStrategyFactoryV3.sol";

/// @notice Deploy Robinhood Uniswap V3 UFloat infra (4663).
/// @dev Reuses AutoOperatorRegistry + SoteriaFeeManagerRh from V3Deployments4663.
contract DeployUFloatRhV3 is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_WALLET_KEY");
        address deployer = vm.addr(pk);

        address registry = V3Deployments4663.OPERATOR_REGISTRY;
        address feeManager = V3Deployments4663.FEE_MANAGER;

        vm.startBroadcast(pk);

        UFloatSwapRouterV3 swapRouter = new UFloatSwapRouterV3();
        console2.log("UFloatSwapRouterV3", address(swapRouter));

        _trySeed(swapRouter, V3Deployments4663.DEMETER_RH_1);
        _trySeed(swapRouter, V3Deployments4663.DEMETER_RH_2);
        _trySeed(swapRouter, V3Deployments4663.TRITON_RH_1);
        _trySeed(swapRouter, V3Deployments4663.TRITON_RH_2);

        UFloatKeeperV3 keeper = new UFloatKeeperV3(registry);
        console2.log("UFloatKeeperV3", address(keeper));

        UFloatStrategyFactoryV3.InfraConfig memory infra = UFloatStrategyFactoryV3.InfraConfig({
            swapRouter: address(swapRouter),
            operatorRegistry: registry,
            keeper: address(keeper),
            feeManager: feeManager
        });
        UFloatStrategyFactoryV3 factory = new UFloatStrategyFactoryV3(infra);
        console2.log("UFloatStrategyFactoryV3", address(factory));

        swapRouter.setStrategyFactory(address(factory));
        keeper.setStrategyFactory(address(factory));

        vm.stopBroadcast();

        console2.log("OperatorRegistry", registry);
        console2.log("feeManager", feeManager);
        console2.log("Deployer", deployer);
        console2.log("Registered assets", swapRouter.registeredAssetCount());
    }

    function _trySeed(UFloatSwapRouterV3 router, address asset) internal {
        uint24[3] memory fees = [uint24(500), uint24(3000), uint24(10000)];
        for (uint256 i = 0; i < fees.length; i++) {
            bool ok = router.trySetPoolConfig(asset, fees[i]);
            if (ok) {
                console2.log("Seeded", asset, fees[i]);
                return;
            }
        }
        console2.log("No pool for seed asset", asset);
    }
}
