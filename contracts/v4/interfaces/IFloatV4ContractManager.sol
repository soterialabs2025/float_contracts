// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFloatV4ContractManager
/// @notice Address registry for the v4 deployment set (separate from `IContractManager` / v3 tooling).
interface IFloatV4ContractManager {
    function getAddress(string memory name) external view returns (address);
}
