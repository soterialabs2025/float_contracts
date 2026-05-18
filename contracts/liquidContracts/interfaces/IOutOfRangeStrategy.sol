// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;  
/// @title IOutOfRangeStrategy
/// @notice Minimal interface to interact with your Strategy
interface IOutOfRangeStrategy {
    /// @return 0 = NORMAL, 1 = DEFENSIVE, 2 = OFFENSIVE
    function mode() external view returns (uint8);
    /// @return Number of consecutive times OFFENSIVE was triggered (reset on DEFENSIVE or asset change)
    function consecutiveOffensiveCount() external view returns (uint256);
    /// @return Unix time when strategy entered DEFENSIVE (0 if not defensive or unsupported)
    function defensiveEnteredAt() external view returns (uint256);
}
