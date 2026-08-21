// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IShareStakingRhV3 {
    /// @notice Pull is not used — strategy transfers tokens first, then calls this.
    function notifyReward(address token, uint256 amount) external;
}
