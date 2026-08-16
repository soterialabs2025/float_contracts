// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {V4Deployments4663} from "../contracts/ustrategy-rh-v4/V4Deployments4663.sol";
import {UFloatSwapRouter} from "../contracts/ustrategy-rh-v4/UFloatSwapRouter.sol";
import {UFloatKeeper} from "../contracts/ustrategy-rh-v4/UFloatKeeper.sol";
import {UFloatStrategyFactoryV4} from "../contracts/ustrategy-rh-v4/UFloatStrategyFactoryV4.sol";

/// @notice Deploy Robinhood Uniswap V4 UFloat infra (4663).
/// @dev Reuses AutoOperatorRegistry + SoteriaFeeManagerRh. Register PoolKeys via setV4PoolConfig before deployStrategy.
contract DeployUFloatRhV4 is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_WALLET_KEY");
        address deployer = vm.addr(pk);

        address registry = V4Deployments4663.OPERATOR_REGISTRY;
        address feeManager = V4Deployments4663.FEE_MANAGER;

        vm.startBroadcast(pk);

        UFloatSwapRouter swapRouter = new UFloatSwapRouter();
        console2.log("UFloatSwapRouter", address(swapRouter));

        UFloatKeeper keeper = new UFloatKeeper(registry);
        console2.log("UFloatKeeper", address(keeper));

        UFloatStrategyFactoryV4.InfraConfig memory infra = UFloatStrategyFactoryV4.InfraConfig({
            swapRouter: address(swapRouter),
            operatorRegistry: registry,
            keeper: address(keeper),
            feeManager: feeManager
        });
        UFloatStrategyFactoryV4 factory = new UFloatStrategyFactoryV4(infra);
        console2.log("UFloatStrategyFactoryV4", address(factory));

        swapRouter.setStrategyFactory(address(factory));
        keeper.setStrategyFactory(address(factory));

        vm.stopBroadcast();

        console2.log("OperatorRegistry", registry);
        console2.log("feeManager", feeManager);
        console2.log("Deployer", deployer);
        console2.log("Registered assets", swapRouter.registeredAssetCount());
        console2.log("aeWETH", V4Deployments4663.WETH);
    }
}
