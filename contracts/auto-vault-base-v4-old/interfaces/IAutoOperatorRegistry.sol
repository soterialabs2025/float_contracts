// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Shared operator allowlist for AutoKeeper wallet sharding.
interface IAutoOperatorRegistry {
    function isOperator(address account) external view returns (bool);
}
