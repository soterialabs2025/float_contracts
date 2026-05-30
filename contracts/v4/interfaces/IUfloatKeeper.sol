// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IUFloatKeeper
/// @notice Keeper orchestration for standalone `UFloatStrategyV4` instances (no vault / contract manager).
interface IUFloatKeeper {
    function addStrategy(address strat) external returns (uint256 id);

    function setStrategyFactory(address factory) external;

    function strategyFactory() external view returns (address);
}
