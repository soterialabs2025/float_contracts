// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IOutOfRangeStrategyV4
/// @notice Keeper-facing strategy controls for the v4 stack only.
interface IOutOfRangeStrategyV4 {
    /// @return 0 = NORMAL, 1 = DEFENSIVE, 2 = OFFENSIVE, 3 = NEUTRAL
    function mode() external view returns (uint8);
    function consecutiveOffensiveCount() external view returns (uint256);
    function defensiveEnteredAt() external view returns (uint256);
    function harvestBoolean(bool skipIncreaseLiquidity) external returns (uint256 newAssets);
    function keeperCheck() external returns (bool);
}
