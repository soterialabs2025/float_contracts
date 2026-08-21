// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./UFloatStrategy.sol";
import "./UStrategyManager.sol";
import "./interfaces/IUFloatV4StrategySwapRouter.sol";
import "./interfaces/IUFloatKeeper.sol";

/// @title UFloatStrategyFactoryV4
/// @notice Clones `UFloatStrategyV4` from a single implementation (keeps factory under EIP-170).
/// @dev    Router and keeper must call `setStrategyFactory(address(this))` after factory deploy.
///         `tokens[0]` becomes the strategy ASSET; owner only needs `depositETH` to mint LP.
contract UFloatStrategyFactoryV4 is Ownable {
    struct InfraConfig {
        address swapRouter;
        address operatorRegistry;
        address keeper;
        address feeManager;
    }

    InfraConfig public infra;
    address public immutable implementation;

    /// @notice Strategies deployed for each owner (append-only; index 0 = oldest).
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
        ) {
            revert ZeroAddress();
        }
        infra = config;
        implementation = address(new UFloatStrategyV4(address(this))); 
    }

    function updateInfra(InfraConfig calldata config) external onlyOwner {
        if (
            config.swapRouter == address(0) || config.operatorRegistry == address(0) || config.keeper == address(0)
                || config.feeManager == address(0)
        ) {
            revert ZeroAddress();
        }
        infra = config;
    }

    function deployStrategy(
        UStrategyManager.StratMethod stratMethod,
        address[] calldata tokens
    ) external returns (address strategy, uint256 keeperId) {
        return _deployStrategy(msg.sender, stratMethod, tokens);
    }

    /// @notice All strategies deployed for `owner_` via this factory (oldest first).
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
        IUFloatV4StrategySwapRouter router = IUFloatV4StrategySwapRouter(infra.swapRouter);
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            if (tokens[i] == address(0)) revert ZeroAddress();
            if (!router.hasV4PoolConfig(tokens[i])) revert AssetNotOnRouter();
        }
        strategy = Clones.clone(implementation);
        UFloatStrategyV4 strat = UFloatStrategyV4(payable(strategy));
        strat.bootstrapStrategy( 
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
