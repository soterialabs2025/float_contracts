// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice `FloatSwapRouterV4` strict entry for strategy rebalances and registry-driven v4 swaps.
/// @dev    Asset-keyed: callers pass the float asset address (and direction) instead of a `PoolKey`,
///         and the router resolves `(PoolKey, hookData)` from `_v4PoolConfig`. Slippage / price-impact
///         bounds live in router storage (`strictStrategySlippageBps`, `maxPriceImpactBps`).
interface IV4StrategySwapRouterStrict {
    /// @notice Quoter-derived `minOut` (`strictStrategySlippageBps`) + post-swap `sqrtPriceX96` impact bound (`maxPriceImpactBps`).
    function swapExactInputSingleStrict(
        address assetAddress,
        bool zeroForOne,
        uint128 amountIn
    ) external returns (uint256 amountOut);

    /// @notice Register / overwrite the v4 pool config for `assetAddress`. `assetAddress` must be one of `key.currency{0,1}`.
    /// @dev    Restricted to `owner` or `configManager` on the implementation.
    function setV4PoolConfig(address assetAddress, PoolKey calldata key, bytes calldata hookData) external;

    /// @notice Read back the registered pool config for `assetAddress` (reverts if unset).
    function getV4PoolConfig(address assetAddress) external view returns (PoolKey memory key, bytes memory hookData);

    /// @notice All asset addresses with a registered v4 pool config (constructor seeds + `setV4PoolConfig`).
    function getRegisteredAssets() external view returns (address[] memory);

    function registeredAssetCount() external view returns (uint256);
}
