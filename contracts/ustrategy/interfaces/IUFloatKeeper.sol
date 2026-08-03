// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IUFloatKeeper
/// @notice Keeper orchestration for standalone `UFloatStrategyV4` instances (no vault / contract manager).
interface IUFloatKeeper {
    struct PoolValueSnapshot {
        uint256 valueWeth;
        uint256 uniswapFeesCollected;
        uint64 timestamp;
    }

    function addStrategy(address strat) external returns (uint256 id);

    function setStrategyFactory(address factory) external;

    function strategyFactory() external view returns (address);

    /// @notice Harvest then snapshot strategy NAV + UniswapFeesCollected for watched strategy `id`.
    /// @notice Snapshot strategy NAV + UniswapFeesCollected (no harvest).
    function snapshotPoolValue(uint256 id) external;

    function getPoolValueSnapshotCount(address strategy) external view returns (uint256);

    function poolValueSnapshots(address strategy, uint256 index)
        external
        view
        returns (uint256 valueWeth, uint256 uniswapFeesCollected, uint64 timestamp);
}
