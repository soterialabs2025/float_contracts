// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUFloatStrategyV4 {
    function keeperCheck() external returns (bool);
    function harvestBoolean(bool skipIncreaseLiquidity) external returns (uint256 newAssets);
    function mode() external view returns (uint8);
    function consecutiveOffensiveCount() external view returns (uint256);
    function defensiveEnteredAt() external view returns (uint256);
}
