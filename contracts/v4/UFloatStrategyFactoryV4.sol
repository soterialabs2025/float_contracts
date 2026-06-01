// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "./UfloatStrategy.sol";
import "./interfaces/IUFloatV4StrategySwapRouter.sol";
import "./interfaces/IUFloatKeeper.sol";

/// @title UFloatStrategyFactoryV4
/// @notice Clones `UFloatStrategyV4` from a single implementation (keeps factory under EIP-170).
/// @dev    Router and keeper must call `setStrategyFactory(address(this))` after factory deploy.
///         `tokens[0]` becomes the strategy ASSET; owner only needs `depositWeth` to mint LP.
contract UFloatStrategyFactoryV4 {
    struct InfraConfig {
        address swapRouter;
        address triton;
        address keeper;
    }

    InfraConfig public infra;
    address public immutable implementation;

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

    constructor(InfraConfig memory config) {
        if (config.swapRouter == address(0) || config.triton == address(0) || config.keeper == address(0)) {
            revert ZeroAddress();
        }
        infra = config;
        implementation = address(new UFloatStrategyV4(address(this)));
    }

    function deployStrategy(
        address[] calldata tokens
    ) external returns (address strategy, uint256 keeperId) {
        return _deployStrategy(msg.sender, tokens);
    }

    function deployStrategyFor(
        address strategyOwner,
        address[] calldata tokens
    ) external returns (address strategy, uint256 keeperId) {
        if (strategyOwner == address(0)) revert ZeroAddress();
        return _deployStrategy(strategyOwner, tokens);
    }

    function _deployStrategy(
        address strategyOwner,
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
            infra.triton,
            infra.keeper,
            tokens
        );

        router.addAuthorizedStrategy(strategy);
        keeperId = IUFloatKeeper(infra.keeper).addStrategy(strategy);

        emit StrategyDeployed(strategy, strategyOwner, tokens[0], keeperId, len);
    }
}
