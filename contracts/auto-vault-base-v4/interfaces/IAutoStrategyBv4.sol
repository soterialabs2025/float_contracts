// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../libraries/LiquidityLibraryV4.sol";

interface IAutoStrategyBv4 {
    enum WithdrawToken {
        WETH,
        ASSET
    }

    function poolValue() external view returns (uint256);
    function minOutForSwap(address tokenIn, uint256 amount) external view returns (uint256);
    function UniswapFeesCollected() external view returns (uint256);
    function vault() external view returns (address);
    function keeper() external view returns (address);
    function ASSET() external view returns (address);
    function poolKey() external view returns (LiquidityLibraryV4.PoolKey memory);
    function hookData() external view returns (bytes memory);

    function keeperCheck() external returns (bool);
    function refreshPriceRef() external returns (bool);
    function poolValueRef() external view returns (uint256);
    function harvestBoolean(bool skipIncreaseLiquidity) external returns (uint256);

    function syncFees() external;
    function deposit(uint256 amount) external;
    function withdraw(uint256 userShares, address receiver, WithdrawToken outToken) external;

    function setWatched(bool status) external;
}
