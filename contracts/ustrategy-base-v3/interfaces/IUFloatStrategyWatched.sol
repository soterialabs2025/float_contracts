// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Keeper-synced watch flag (mirrors `UFloatKeeper` `active` for this strategy id).
interface IUFloatStrategyWatched {
    function watched() external view returns (bool);

    /// @dev Callable only by the strategy's configured keeper (`keeperStratAddr`).
    function setWatched(bool status) external;
}
