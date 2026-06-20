// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./UfloatStrategy.sol";
import "./UStrategyManager.sol";
import "./interfaces/IUFloatV4StrategySwapRouter.sol";
import "./interfaces/IUFloatKeeper.sol";

/// @title UFloatStrategyFactoryV4
/// @notice Clones `UFloatStrategyV4` from a single implementation (keeps factory under EIP-170).
/// @dev    Router and keeper must call `setStrategyFactory(address(this))` after factory deploy.
///         `tokens[0]` becomes the strategy ASSET; owner only needs `depositWeth` to mint LP.
contract UFloatStrategyFactoryV4 is Ownable {
    struct InfraConfig {
        address swapRouter;
        address operatorRegistry;
        address keeper;
    }

    InfraConfig public infra;
    address public immutable implementation;

    /// @notice ERC20 required to call deploy functions. `address(0)` disables the gate.
    address public deployGateToken;
    /// @notice Minimum `deployGateToken` balance for `msg.sender` when the gate is enabled.
    uint256 public minDeployGateBalance;

    error ZeroAddress();
    error EmptyTokenList();
    error AssetNotOnRouter();
    error InsufficientDeployGateBalance();

    event StrategyDeployed(
        address indexed strategy,
        address indexed owner,
        address indexed firstAsset,
        uint256 keeperId,
        uint256 allowedTokenCount
    );
    event InfraUpdated(address indexed swapRouter, address indexed operatorRegistry, address indexed keeper);
    event DeployGateUpdated(address indexed deployGateToken, uint256 minDeployGateBalance);

    constructor(InfraConfig memory config) Ownable(msg.sender) {
        if (config.swapRouter == address(0) || config.operatorRegistry == address(0) || config.keeper == address(0)) {
            revert ZeroAddress();
        }
        infra = config;
        implementation = address(new UFloatStrategyV4(address(this)));
    }

    /// @notice Update router / operator registry / keeper wired into newly deployed strategies.
    /// @dev    After changing router or keeper, call `setStrategyFactory(address(this))` on the new contracts.
    function updateInfra(InfraConfig calldata config) external onlyOwner {
        if (config.swapRouter == address(0) || config.operatorRegistry == address(0) || config.keeper == address(0)) {
            revert ZeroAddress();
        }
        infra = config;
        emit InfraUpdated(config.swapRouter, config.operatorRegistry, config.keeper);
    }

    /// @notice Set deploy gate token and minimum balance. Pass `address(0)` to disable the gate.
    function updateDeployGate(address token, uint256 minBalance) external onlyOwner {
        deployGateToken = token;
        minDeployGateBalance = minBalance;
        emit DeployGateUpdated(token, minBalance);
    }

    function deployStrategy(
        UStrategyManager.StratMethod stratMethod,
        address[] calldata tokens
    ) external returns (address strategy, uint256 keeperId) {
        return _deployStrategy(msg.sender, stratMethod, tokens);
    }

    function _deployStrategy(
        address strategyOwner,
        UStrategyManager.StratMethod stratMethod,
        address[] calldata tokens
    ) internal returns (address strategy, uint256 keeperId) {
        _requireDeployGate(msg.sender);

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
            stratMethod,
            tokens
        );

        router.addAuthorizedStrategy(strategy);
        keeperId = IUFloatKeeper(infra.keeper).addStrategy(strategy);

        emit StrategyDeployed(strategy, strategyOwner, tokens[0], keeperId, len);
    }

    function _requireDeployGate(address account) internal view {
        address gateToken = deployGateToken;
        if (gateToken == address(0)) return;
        if (IERC20(gateToken).balanceOf(account) < minDeployGateBalance) {
            revert InsufficientDeployGateBalance();
        }
    }
}
