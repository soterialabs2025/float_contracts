// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFloatStrategy {
  /// @notice Cumulative WETH-notional LP fees recorded by the strategy (drives vault fee-per-share accounting).
  function UniswapFeesCollected() external view returns (uint256);

  function enterNeutralFromVault() external;
  function resumeNormalFromVault() external;

  function getPositionId() external view returns (uint256);
  function beforeDeposit() external;
  function deposit(uint256 amount) external;
  function poolValue() external view returns (uint256);
  function withdraw(uint256 userShares, uint256 totalSupply, address receiver) external;
  function readInRange() external view returns (bool);
  function balanceOfIdle() external view returns (uint256);
  function balanceOfPool() external view returns (uint256 tokenAmt, uint256 wethAmt);
  function changeAsset(address _newAssetAddr, address _newPoolV3Addr) external;
  function totalLiquidity() external view returns (uint128);
}
