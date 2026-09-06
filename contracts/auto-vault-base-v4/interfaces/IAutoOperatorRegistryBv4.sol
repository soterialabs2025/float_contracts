// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared operator allowlist for AutoKeeperBv4 wallet sharding.
interface IAutoOperatorRegistryBv4 {
    function isOperator(address account) external view returns (bool);
}
