// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./UFloatStrategyV3.sol";
import "./UStrategyManager.sol";
import "./interfaces/IUFloatV3StrategySwapRouter.sol";
import "./interfaces/IUFloatKeeper.sol";

/// @title UFloatStrategyFactoryV3
/// @notice Clones UFloatStrategyV3. Router must have pool fee configs for each token (no PoolKey).
contract UFloatStrategyFactoryV3 is Ownable {
    struct InfraConfig {
        address swapRouter;
        address operatorRegistry;
        address keeper;
        address feeManager;
    }

    InfraConfig public infra;
    address public immutable implementation;
    mapping(address => address[]) private _strategiesByOwner;

    error ZeroAddress();
    error EmptyTokenList();
    error AssetNotOnRouter();

    event StrategyDeployed(
        address indexed strategy,
        address indexed owner,
        address indexed firstAsset,
        uint256 keeperId,
        uint256 allowedTokenCount
    );

    constructor(InfraConfig memory config) Ownable(msg.sender) {
        if (
            config.swapRouter == address(0) || config.operatorRegistry == address(0) || config.keeper == address(0)
                || config.feeManager == address(0)
        ) revert ZeroAddress();
        infra = config;
        implementation = address(new UFloatStrategyV3(address(this)));
    }

    function updateInfra(InfraConfig calldata config) external onlyOwner {
        if (
            config.swapRouter == address(0) || config.operatorRegistry == address(0) || config.keeper == address(0)
                || config.feeManager == address(0)
        ) revert ZeroAddress();
        infra = config;
    }

    function deployStrategy(UStrategyManager.StratMethod stratMethod, address[] calldata tokens)
        external
        returns (address strategy, uint256 keeperId)
    {
        return _deployStrategy(msg.sender, stratMethod, tokens);
    }

    function getStrategies(address owner_) external view returns (address[] memory) {
        return _strategiesByOwner[owner_];
    }

    function strategiesOfOwnerLength(address owner_) external view returns (uint256) {
        return _strategiesByOwner[owner_].length;
    }

    function _deployStrategy(
        address strategyOwner,
        UStrategyManager.StratMethod stratMethod,
        address[] calldata tokens
    ) internal returns (address strategy, uint256 keeperId) {
        if (tokens.length == 0) revert EmptyTokenList();
        IUFloatV3StrategySwapRouter router = IUFloatV3StrategySwapRouter(infra.swapRouter);
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            if (tokens[i] == address(0)) revert ZeroAddress();
            if (!router.hasPoolConfig(tokens[i])) revert AssetNotOnRouter();
        }
        strategy = Clones.clone(implementation);
        UFloatStrategyV3(payable(strategy)).bootstrapStrategy(
            strategyOwner,
            infra.swapRouter,
            infra.operatorRegistry,
            infra.keeper,
            infra.feeManager,
            stratMethod,
            tokens
        );
        router.addAuthorizedStrategy(strategy);
        keeperId = IUFloatKeeper(infra.keeper).addStrategy(strategy);
        _strategiesByOwner[strategyOwner].push(strategy);
        emit StrategyDeployed(strategy, strategyOwner, tokens[0], keeperId, len);
    }
}
