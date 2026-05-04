// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFloatStrategyV4
/// @notice Float vault ↔ strategy surface for the Uniswap v4 stack only (not ABI-compatible with `IFloatStrategy`).
interface IFloatStrategyV4 {
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
    /// @notice Switch asset and Uniswap v4 pool identity for ASSET/WETH.
    /// @param poolFeePips_ Pool `fee` field (hundredths of a bip): e.g. 500 = 0.05%, 3000 = 0.30%, 10_000 = 1%.
    /// @param tickSpacing_ Must match the pool initialized for `(ASSET, WETH, fee, tickSpacing_, hooks_)`.
    /// @param hooks_ Pool hooks contract, or `address(0)` for no hooks.
    function changeAsset(address _newAssetAddr, uint24 poolFeePips_, int24 tickSpacing_, address hooks_) external;
    function totalLiquidity() external view returns (uint128);
}
