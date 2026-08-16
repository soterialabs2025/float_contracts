// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IOutOfRangeStrategyV3
/// @notice Keeper-facing strategy controls for the v3 stack only.
interface IOutOfRangeStrategyV3 {
    /// @return 0 = NORMAL, 1 = DEFENSIVE, 2 = OFFENSIVE, 3 = STABLE (WETH-only)
    function mode() external view returns (uint8);
    function consecutiveOffensiveCount() external view returns (uint256);
    function harvestBoolean(bool skipIncreaseLiquidity) external returns (uint256 newAssets);
    function keeperCheck() external returns (bool);
}
