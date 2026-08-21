// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAutoSwapRouterBv3 {
    function swapExactInputSingleStrict(address tokenIn, address tokenOut, uint24 fee, uint128 amountIn)
        external
        returns (uint256 amountOut);

    function addAuthorizedStrategy(address strategy) external;
}
