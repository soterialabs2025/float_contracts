// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal interface for keeper-triggered vault snapshots.
interface IFloatVault {
    function recordPoolValueSnapshot() external;
}
