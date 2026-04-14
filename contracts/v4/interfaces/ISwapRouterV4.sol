// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice V4-only swap helper: Universal Router `V4_SWAP` + Permit2 (no v3 path encoding).
interface ISwapRouterV4 {
    /// @notice Pull `tokenIn` from caller, swap to WETH on a single v4 pool, send WETH to `recipient`.
    /// @dev Tries fee tiers 500 → 3000 → 10000 (Uniswap v4 default tick spacings). Uses `quoterV4` when set for min-out; otherwise `minOut` must be supplied.
    function swapToWethViaUniversalRouterV4(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        uint128 minOutIfNoQuoter
    ) external returns (uint256 amountOut);
}
