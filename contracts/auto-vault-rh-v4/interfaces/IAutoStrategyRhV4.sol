// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../libraries/LiquidityLibraryV4.sol";

interface IAutoStrategyRhV4 {
    enum WithdrawToken {
        WETH,
        ASSET
    }

    function poolValue() external view returns (uint256);
    function minOutForSwap(bool sellEth, uint256 amount) external view returns (uint256);
    function balance() external view returns (uint256);
    function UniswapFeesCollected() external view returns (uint256);
    function vault() external view returns (address);
    function keeper() external view returns (address);
    function ASSET() external view returns (address);
    function poolKey() external view returns (LiquidityLibraryV4.PoolKey memory);
    function hookData() external view returns (bytes memory);

    function keeperCheck() external returns (bool);
    function refreshTickAnchor() external returns (bool);
    function harvestBoolean(bool skipIncreaseLiquidity) external returns (uint256);

    function deposit() external payable;
    function withdraw(uint256 userShares, address receiver, WithdrawToken outToken) external;

    function setWatched(bool status) external;
}
