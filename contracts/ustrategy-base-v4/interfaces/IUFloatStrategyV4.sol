// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IUFloatStrategyAllowedTokens.sol";

/// @title IUFloatStrategyV4
/// @notice Standalone v4 strategy (no FloatVault / share token). Owner funds via ETH; withdraws WETH.
interface IUFloatStrategyV4 is IUFloatStrategyAllowedTokens {
    function UniswapFeesCollected() external view returns (uint256);

    function getPositionId() external view returns (uint256);

    /// @notice Wrap msg.value to WETH and deploy into LP per mode rules (owner only).
    function depositETH() external payable;

    /// @notice Withdraw WETH notional to owner. Pass `type(uint256).max` (or any amount >= `totalValueWeth()`) to fully exit in one tx.
    function withdrawWeth(uint256 wethAmount) external;

    function poolValue() external view returns (uint256);
    function balanceOfIdle() external view returns (uint256);
    function balanceOfPool() external view returns (uint256 tokenAmt, uint256 wethAmt);
    function totalValueWeth() external view returns (uint256);

    /// @notice Rotate to `_newAssetAddr` (or WETH for STABLE exit). Pool key is read from `UFloatSwapRouter`.
    function changeAsset(address _newAssetAddr) external;

    /// @notice Flatten LP, swap to WETH, enter STABLE. Owner or demeter.
    function exitToStable() external;

    /// @notice Flatten if needed and mint via `_changeAsset`. Same ASSET remints with current band params;
    ///         other allowlisted token rotates; WETH exits to STABLE.
    function mintPosition(address token) external;
}
