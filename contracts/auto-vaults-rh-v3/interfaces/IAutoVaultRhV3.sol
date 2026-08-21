// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAutoVaultRhV3 {
    struct PoolValueSnapshot {
        uint256 valueWeth;
        uint256 uniswapFeesCollected;
        uint64 timestamp;
    }

    function depositETH() external payable returns (uint256 shares);
    /// @param asAsset true → receive ASSET; false → receive WETH
    function withdraw(uint256 shares, bool asAsset) external returns (uint256 assets);

    function balance() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);

    function recordPoolValueSnapshot() external;
    function getPoolValueSnapshotCount() external view returns (uint256);
    function poolValueSnapshots(uint256 index)
        external
        view
        returns (uint256 valueWeth, uint256 uniswapFeesCollected, uint64 timestamp);
}
