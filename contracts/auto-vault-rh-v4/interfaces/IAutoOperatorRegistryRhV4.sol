// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Shared operator allowlist for AutoKeeperRhV4 wallet sharding.
interface IAutoOperatorRegistryRhV4 {
    function isOperator(address account) external view returns (bool);
}
