// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Shared operator allowlist for AutoKeeperBv3 wallet sharding.
interface IAutoOperatorRegistryBv3 {
    function isOperator(address account) external view returns (bool);
}
