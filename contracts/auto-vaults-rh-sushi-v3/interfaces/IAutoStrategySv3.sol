// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAutoStrategySv3 {
    enum WithdrawToken {
        WETH,
        ASSET
    }

    function poolValue() external view returns (uint256);
    function poolValueTwap() external view returns (uint256);
    function balance() external view returns (uint256);
    function UniswapFeesCollected() external view returns (uint256);
    function vault() external view returns (address);
    function keeper() external view returns (address);
    function ASSET() external view returns (address);
    function poolFee() external view returns (uint24);
    function pool() external view returns (address);
    function keeperCheck() external returns (bool);
    function harvestBoolean(bool skipIncreaseLiquidity) external returns (uint256);
    function deposit(uint256 amount) external;
    function withdraw(uint256 userShares, address receiver, WithdrawToken outToken) external;
    function setWatched(bool status) external;
}
