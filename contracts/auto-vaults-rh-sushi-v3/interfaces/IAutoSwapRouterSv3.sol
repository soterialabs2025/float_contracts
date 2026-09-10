// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IAutoSwapRouterSv3 {
    /// @param maxDevBps How far spot may sit from the pool TWAP and still be accepted as the pricing basis.
    ///        Caller-supplied because exits tolerate more drift than rebalances: a skipped rebalance retries,
    ///        a blocked exit strands a user.
    /// @param slipBps Haircut on the TWAP-admitted floor. Same pairing: rebalances pass the tight value, exits the
    ///        widened one.
    /// @param deadline Latest block timestamp the swap may execute at. `0` disables the check.
    function swapExactInputSingleStrict(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint128 amountIn,
        uint256 maxDevBps,
        uint256 slipBps,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function addAuthorizedStrategy(address strategy) external;
    function removeAuthorizedStrategy(address strategy) external;
}
