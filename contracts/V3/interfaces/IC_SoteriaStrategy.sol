// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IC_SoteriaStrategy {
  function getPositionId() external view returns (uint256);
  function beforeDeposit() external;
  function deposit(uint256 amount) external;
  function balanceOf() external view returns (uint256);
  function totalLiquidity() external view returns (uint128);
  function poolValue() external view returns (uint256);
  function withdraw(uint256 userShares, uint256 totalSupply, address receiver) external;
  function readInRange() external view returns (bool);
  function balanceOfWant() external view returns (uint256);
  function balanceOfPool() external view returns (uint256 tokenAmt, uint256 wethAmt);
  function changeAsset(address _newAssetAddr, address _newPoolV3Addr) external;
}

