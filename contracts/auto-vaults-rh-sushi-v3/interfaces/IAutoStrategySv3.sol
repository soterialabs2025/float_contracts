// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IAutoStrategySv3 {
    enum WithdrawToken {
        WETH,
        ASSET
    }

    function poolValue() external view returns (uint256);
    function poolValueTwap() external view returns (uint256);
    /// @notice Ungated TWAP NAV for the minting path. `0` only when the oracle itself cannot be read.
    function poolValueTwapRaw() external view returns (uint256);
    /// @notice TWAP-derived output floor for swapping `amount` of `tokenIn`, at the rebalance band.
    /// @return `0` when the oracle is unusable or spot has left the TWAP band, meaning the caller must not swap.
    function minOutForSwap(address tokenIn, uint256 amount) external view returns (uint256);
    /// @notice Same floor at the wider band withdrawals use. Lets a caller see whether an exit would price.
    function minOutForWithdraw(address tokenIn, uint256 amount) external view returns (uint256);
    function balance() external view returns (uint256);
    function UniswapFeesCollected() external view returns (uint256);
    function vault() external view returns (address);
    function keeper() external view returns (address);
    function ASSET() external view returns (address);
    function poolFee() external view returns (uint24);
    function pool() external view returns (address);
    function keeperCheck() external returns (bool);
    function harvestBoolean(bool skipIncreaseLiquidity) external returns (uint256);
    function syncFees() external;
    function deposit(uint256 amount) external;
    function withdraw(uint256 userShares, address receiver, WithdrawToken outToken) external;
    function setWatched(bool status) external;
}
