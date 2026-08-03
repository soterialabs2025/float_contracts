// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICLAdapter {
  
  struct AddParams {
    address token0; address token1;
    uint24 fee; int24 tickLower; int24 tickUpper;
    uint256 amt0; uint256 amt1; uint256 min0; uint256 min1;
    address recipient; uint256 deadline;
  }
  /// @return positionId (e.g., Uni v3 NFT id), liqAdded, used0, used1
  function addLiquidity(AddParams calldata p) external returns (uint256, uint128, uint256, uint256);

  /// remove part/all liquidity; returns amounts received
  function removeLiquidity(uint256 positionId, uint128 liquidity, uint256 min0, uint256 min1, uint256 deadline)
    external returns (uint256 amt0, uint256 amt1);

  /// collect accrued fees on the position
  function collectFees(uint256 positionId, address to) external returns (uint256 amt0, uint256 amt1);

  /// emergency withdraw all liquidity from position
  function emergencyWithdraw(uint256 positionId) external; 

  /// spot/twap helpers, tick math, etc. (optional)
}
