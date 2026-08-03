// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interface for SwapRouter contract
interface ISwapRouter {

    function swapExactInputFromStrategy(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external returns (uint256 amountOut);

    /// @notice Strategy path: strict QuoterV2 min-out + optional TWAP floor; min-out uses `strictStrategySlippageBps` on router.
    function swapExactInputFromStrategyStrictQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external returns (uint256 amountOut);

    function swapAssetToNewAsset(
        address oldAssetAddr,
        address newAssetAddr,
        uint256 amountIn,
        address recipient
    ) external returns (uint256 amountOut);


    /// @notice Swap token to WETH via Uniswap UniversalRouter + Permit2.
    /// @dev Caller must approve this router for tokenIn. Tries V3 fee tiers 0.05% → 0.3% → 1%.
    function swapToWethViaUniversalRouter(
        address tokenIn,
        uint256 amountIn,
        address recipient
    ) external returns (uint256 amountOut);
}

