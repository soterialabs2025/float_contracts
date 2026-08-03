// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

/// @title Interface for ERC20 Token Contracts
/// @notice Proposal Storage contracts call ERC20 contracts through this Interface.

interface IERC20 {
    function balanceOf(address account) external view returns (uint);
    function transfer(address recipient, uint amount) external returns (bool);
}