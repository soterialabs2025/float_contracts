// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./UfloatStrategy.sol";
import "./interfaces/IUfloatV4StrategySwapRouter.sol";
import "./interfaces/IUfloatKeeper.sol";

/// @title UfloatStrategyFactory
/// @notice Deploys `UfloatStrategyV4` instances and registers them on `UfloatSwapRouter` + `UfloatKeeper`.
/// @dev    Router and keeper must call `setStrategyFactory(address(this))` after factory deploy.
contract UfloatStrategyFactory {
    struct InfraConfig {
        address weth;
        address positionManager;
        address poolManager;
        address swapRouter;
        address demeter;
        address keeper;
    }

    InfraConfig public infra;

    error ZeroAddress();
    error AssetNotOnRouter();

    event StrategyDeployed(
        address indexed strategy,
        address indexed owner,
        address indexed asset,
        uint256 keeperId,
        address manager
    );

    constructor(InfraConfig memory config) {
        if (
            config.weth == address(0) ||
            config.positionManager == address(0) ||
            config.poolManager == address(0) ||
            config.swapRouter == address(0) ||
            config.demeter == address(0) ||
            config.keeper == address(0)
        ) {
            revert ZeroAddress();
        }
        infra = config;
    }

    /// @notice Deploy a strategy owned by `msg.sender`.
    /// @param assetAddr Initial ASSET (must exist on `UfloatSwapRouter` pool registry).
    /// @param managerAddr Strategy ops address (`changeAsset`, harvest auth alongside demeter / keeper).
    /// @param keeperMinInterval Minimum seconds between keeper actions for this strategy (0 = no limit).
    function deployStrategy(
        address assetAddr,
        address managerAddr,
        uint32 keeperMinInterval
    ) external returns (address strategy, uint256 keeperId) {
        return _deployStrategy(msg.sender, assetAddr, managerAddr, keeperMinInterval);
    }

    /// @notice Deploy a strategy with an explicit owner (factory caller must be trusted — e.g. admin UI).
    function deployStrategyFor(
        address strategyOwner,
        address assetAddr,
        address managerAddr,
        uint32 keeperMinInterval
    ) external returns (address strategy, uint256 keeperId) {
        if (strategyOwner == address(0)) revert ZeroAddress();
        return _deployStrategy(strategyOwner, assetAddr, managerAddr, keeperMinInterval);
    }

    function _deployStrategy(
        address strategyOwner,
        address assetAddr,
        address managerAddr,
        uint32 keeperMinInterval
    ) internal returns (address strategy, uint256 keeperId) {
        if (assetAddr == address(0)) revert ZeroAddress();
        IUfloatV4StrategySwapRouter router = IUfloatV4StrategySwapRouter(infra.swapRouter);
        if (!router.hasV4PoolConfig(assetAddr)) revert AssetNotOnRouter();

        UfloatStrategyV4 strat = new UfloatStrategyV4(
            infra.weth,
            infra.positionManager,
            infra.poolManager,
            assetAddr,
            managerAddr,
            infra.swapRouter,
            infra.demeter,
            infra.keeper
        );

        strategy = address(strat);

        router.addAuthorizedStrategy(strategy);
        keeperId = IUfloatKeeper(infra.keeper).addStrategy(strategy, keeperMinInterval);

        strat.addAllowedToken(assetAddr);
        strat.transferOwnership(strategyOwner);

        emit StrategyDeployed(strategy, strategyOwner, assetAddr, keeperId, managerAddr);
    }
}
