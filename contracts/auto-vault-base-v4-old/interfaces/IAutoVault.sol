// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAutoVault {
    struct PoolValueSnapshot {
        uint256 valueWeth;
        uint256 uniswapFeesCollected;
        uint64 timestamp;
    }

    function depositETH() external payable returns (uint256 shares);
    function depositWeth(uint256 amount) external returns (uint256 shares);
    function depositAsset(uint256 amount) external returns (uint256 shares);
    /// @param asAsset true → receive ASSET; false → receive WETH
    function withdraw(uint256 shares, bool asAsset) external returns (uint256 assets);
    function enterNeutral() external;
    function resumeNormal() external;

    /// @notice Strategy NAV in WETH-notional (forwards to strategy).
    function balance() external view returns (uint256);
    /// @notice Share balance (forwards to liquid token).
    function balanceOf(address account) external view returns (uint256);
    /// @notice Share supply (forwards to liquid token).
    function totalSupply() external view returns (uint256);

    /// @notice Record NAV + cumulative Uniswap fees. Callable only by AutoKeeper (after harvest).
    function recordPoolValueSnapshot() external;
    function getPoolValueSnapshotCount() external view returns (uint256);
    function poolValueSnapshots(uint256 index)
        external
        view
        returns (uint256 valueWeth, uint256 uniswapFeesCollected, uint64 timestamp);
}
