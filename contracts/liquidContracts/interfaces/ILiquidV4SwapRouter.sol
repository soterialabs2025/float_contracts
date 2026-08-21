// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Minimal v4 swap surface for the liquid stack (`LiquidV4SwapCore` / `LiquidSwapRouterV4`).
interface ILiquidV4SwapRouter {
    function swapExactInputSingleStrict(
        address assetAddress,
        bool zeroForOne,
        uint128 amountIn
    ) external returns (uint256 amountOut);

    function setV4PoolConfig(address assetAddress, PoolKey calldata key, bytes calldata hookData) external;

    function getV4PoolConfig(address assetAddress)
        external
        view
        returns (PoolKey memory key, bytes memory hookData);
}
