// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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

    /// @param minAmountOut Caller-supplied output floor. Must be non-zero; the router does not derive one.
    /// @param deadline Unix timestamp after which the swap reverts. `0` disables the check.
    function swapExactInputSingleStrict(
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        uint256 deadline,
        AutoPoolKey calldata key,
        bytes calldata hookData
    ) external returns (uint256 amountOut);

    function addAuthorizedStrategy(address strategy) external;
}
