// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILiquidTermsVault {
  function deposit(uint256 amount, address receiver) external returns (uint256 shares);
  function withdraw(uint256 shares, address receiver, address owner) external returns (uint256 assets);
  function totalAssets() external view returns (uint256);
  function getPricePerFullShare() external view returns (uint256);
}
