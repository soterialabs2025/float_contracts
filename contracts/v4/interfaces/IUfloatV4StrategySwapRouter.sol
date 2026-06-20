// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "../../../lib/v4-core/src/types/PoolKey.sol";

/// @title IUFloatV4StrategySwapRouter
/// @notice `UFloatSwapRouter` surface: per-asset v4 pool registry and strict swaps for allowlisted `UFloatStrategy` contracts.
interface IUFloatV4StrategySwapRouter {
    /// @notice Quoter-derived `minOut` plus post-swap price-impact bound. Callable only by authorized strategies.
    function swapExactInputSingleStrict(
        address assetAddress,
        bool zeroForOne,
        uint128 amountIn
    ) external returns (uint256 amountOut);

    function setV4PoolConfig(address assetAddress, PoolKey calldata key, bytes calldata hookData) external;

    function getV4PoolConfig(address assetAddress) external view returns (PoolKey memory key, bytes memory hookData);

    /// @notice True when `assetAddress` has a registered pool (either currency slot non-zero).
    function hasV4PoolConfig(address assetAddress) external view returns (bool);

    function addAuthorizedStrategy(address strategy) external;

    function removeAuthorizedStrategy(address strategy) external;

    function isAuthorizedStrategy(address strategy) external view returns (bool);

    function getAuthorizedStrategies() external view returns (address[] memory);

    function setStrategyFactory(address factory) external;

    function strategyFactory() external view returns (address);
}
