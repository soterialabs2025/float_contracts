// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice FloatV4SwapRouter entry for strategy rebalances (single-hop exact-in on `poolKey`).
interface IFloatV4StrategySwapRouter {
    function swapExactInputSingleFromStrategy(
        PoolKey calldata poolKey,
        bool zeroForOne,
        uint256 amountIn,
        uint128 minOutIfNoQuoter
    ) external returns (uint256 amountOut);

    function setStrategy(address s) external;
}
