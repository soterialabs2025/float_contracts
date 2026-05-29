// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IUfloatStrategyAllowedTokens.sol";

/// @title IUfloatStrategyV4
/// @notice Standalone v4 strategy (no FloatVault / share token). Owner funds and withdraws WETH directly.
interface IUfloatStrategyV4 is IUfloatStrategyAllowedTokens {
    function UniswapFeesCollected() external view returns (uint256);

    function getPositionId() external view returns (uint256);

    /// @notice Pull WETH from owner and deploy into LP per mode rules.
    function depositWeth(uint256 amount) external;

    /// @notice Withdraw up to `wethAmount` WETH notional (idle + pro-rata LP) to `receiver`. Pass `type(uint256).max` for full exit.
    function withdrawWeth(uint256 wethAmount, address receiver) external;

    function poolValue() external view returns (uint256);
    function balanceOfIdle() external view returns (uint256);
    function balanceOfPool() external view returns (uint256 tokenAmt, uint256 wethAmt);

    /// @notice Rotate to `_newAssetAddr` (or WETH for STABLE exit). Pool key is read from `UfloatSwapRouter`.
    function changeAsset(address _newAssetAddr) external;

    function totalLiquidity() external view returns (uint128);
}
