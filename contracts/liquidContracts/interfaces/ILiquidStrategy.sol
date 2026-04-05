// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILiquidStrategy {
  /// @notice Optional harvest / rebalance before measuring NAV for deposits.
  function beforeDeposit() external;
  function deposit(uint256 amount) external;
  function vaultValue() external view returns (uint256);
  function withdraw(uint256 userShares, uint256 totalSupply, address receiver) external;
  function readInRange() external view returns (bool);
  function changeAsset(address _newAssetAddr, address _newPoolV3Addr) external;
}
