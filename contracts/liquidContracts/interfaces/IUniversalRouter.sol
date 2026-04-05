// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUniversalRouter {
    /// @notice Executes encoded commands along with provided inputs
    /// @param commands A packed array of command bytes
    /// @param inputs An array of ABI-encoded inputs for each command
    /// @param deadline Timestamp after which execution is invalid
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
}
