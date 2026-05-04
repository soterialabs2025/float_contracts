// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice V4-only swap helper: Universal Router `V4_SWAP` + Permit2 (single-pool V4 path encoding only).
interface ISwapRouterV4 {
    /// @notice Pull non-WETH side of `key` from caller, swap to WETH on that pool, send WETH to `recipient`.
    /// @dev `key` must be the initialized **token / WETH** pool (currencies sorted per v4). Min-out comes from `V4Deployments8453` quoter + `defaultSlippageBps`.
    function swapToWethViaUniversalRouterV4(PoolKey calldata key, uint256 amountIn, address recipient)
        external
        returns (uint256 amountOut);
}
