// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Standalone key layout (same fields as LiquidityLibraryV4.PoolKey) so routers can avoid
///      importing LiquidityLibraryV4 + local TickMath alongside v4-core TickMath.
interface IAutoSwapRouterBv4 {
    struct AutoPoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    function swapExactInputSingleStrict(
        bool zeroForOne,
        uint128 amountIn,
        AutoPoolKey calldata key,
        bytes calldata hookData
    ) external returns (uint256 amountOut);

    function addAuthorizedStrategy(address strategy) external;
}
