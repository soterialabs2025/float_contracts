// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared operator allowlist for AutoKeeperRhV3 wallet sharding.
interface IAutoOperatorRegistryRhV3 {
    function isOperator(address account) external view returns (bool);
}
