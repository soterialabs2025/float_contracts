// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./interfaces/IOperatorRegistry.sol";

interface IUFloatStrategyBootstrap {
    enum StratMethod {
        ReBalanceOnly,
        OffensiveOnly,
        DefensiveOnly,
        OffensiveDefensive
    }

    function bootstrapStrategy(
        address owner_,
        address swapRouter,
        address operatorRegistry_,
        address keeper,
        StratMethod stratMethod_,
        address[] calldata tokens
    ) external;
}

interface IUFloatKeeperRegistry {
    function addStrategy(address strat) external returns (uint256 id);
}

/// @notice Minimal factory sketch — wire your existing deploy gate / implementation pointer.
contract UFloatStrategyFactoryV4 is Ownable {
    using Clones for address;

    struct InfraConfig {
        address swapRouter;
        address operatorRegistry;
        address keeper;
    }

    InfraConfig public infra;
    address public immutable implementation;

    error ZeroAddress();
    error NotOperator();

    constructor(InfraConfig memory config_, address implementation_) Ownable(msg.sender) {
        if (
            config_.swapRouter == address(0) ||
            config_.operatorRegistry == address(0) ||
            config_.keeper == address(0) ||
            implementation_ == address(0)
        ) {
            revert ZeroAddress();
        }
        infra = config_;
        implementation = implementation_;
    }

    function deployStrategyFor(
        address strategyOwner,
        IUFloatStrategyBootstrap.StratMethod stratMethod_,
        address[] calldata tokens
    ) external returns (address strategy, uint256 keeperId) {
        if (strategyOwner == address(0)) revert ZeroAddress();
        if (tokens.length == 0) revert ZeroAddress();

        strategy = implementation.clone();
        IUFloatStrategyBootstrap(strategy).bootstrapStrategy(
            strategyOwner,
            infra.swapRouter,
            infra.operatorRegistry,
            infra.keeper,
            stratMethod_,
            tokens
        );

        keeperId = IUFloatKeeperRegistry(infra.keeper).addStrategy(strategy);
    }

    function updateInfra(InfraConfig calldata config_) external onlyOwner {
        if (
            config_.swapRouter == address(0) ||
            config_.operatorRegistry == address(0) ||
            config_.keeper == address(0)
        ) {
            revert ZeroAddress();
        }
        infra = config_;
    }
}
