// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal vault-facing ERC20 API for `LiquidTokenV4`.
interface ILiquidTokenVault {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}
