// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUFloatV3StrategySwapRouter {
    function swapExactInputSingleStrict(address tokenIn, address tokenOut, uint24 fee, uint128 amountIn)
        external
        returns (uint256);

    function hasPoolConfig(address asset) external view returns (bool);

    function getPoolConfig(address asset) external view returns (uint24 fee);

    function addAuthorizedStrategy(address strategy) external;
}
