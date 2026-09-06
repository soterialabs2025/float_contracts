// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared operator allowlist for AutoKeeperSv3 wallet sharding.
interface IAutoOperatorRegistrySv3 {
    function isOperator(address account) external view returns (bool);
}
