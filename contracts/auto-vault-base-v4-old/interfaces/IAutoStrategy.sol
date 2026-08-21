// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/LiquidityLibraryV4.sol";

interface IAutoStrategy {
    enum Mode { NORMAL, NEUTRAL }
    enum WithdrawToken { WETH, ASSET }

    function mode() external view returns (uint8);
    function poolValue() external view returns (uint256);
    function balance() external view returns (uint256);
    function UniswapFeesCollected() external view returns (uint256);
    function vault() external view returns (address);
    function keeper() external view returns (address);
    function ASSET() external view returns (address);
    function poolKey() external view returns (LiquidityLibraryV4.PoolKey memory);
    function hookData() external view returns (bytes memory);

    function keeperCheck() external returns (bool);
    function harvestBoolean(bool skipIncreaseLiquidity) external returns (uint256);

    function deposit(uint256 amount) external;
    /// @notice Deploy idle ASSET/WETH already held by the strategy (e.g. after vault `depositAsset`).
    function ingestAndDeploy() external;
    function withdraw(
        uint256 userShares,
        address receiver,
        WithdrawToken outToken
    ) external;

    function enterNeutralFromVault() external;
    function resumeNormalFromVault() external;

    function setWatched(bool status) external;
}
