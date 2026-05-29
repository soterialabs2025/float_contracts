// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IUfloatKeeper
/// @notice Keeper orchestration for standalone `UfloatStrategyV4` instances (no vault / contract manager).
interface IUfloatKeeper {
    function addStrategy(address strat, uint32 minInterval) external returns (uint256 id);

    function setStrategyFactory(address factory) external;

    function strategyFactory() external view returns (address);
}
