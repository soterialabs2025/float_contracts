// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Optional lens for FloatVaultV4 `getPositionDetails` (V4 has no NPM `positions()` tuple).
interface IFloatStrategyV4Ticks {
    function tickRange() external view returns (int24 lower, int24 upper);
}
