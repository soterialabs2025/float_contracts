// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFloatVaultV4
/// @notice Minimal keeper hook for v4 vaults (separate from `IFloatVault`).
interface IFloatVaultV4 {
    function recordPoolValueSnapshot() external;
}
