// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IUFloatStrategyAllowedTokens
/// @notice Owner-managed allowlist of asset tokens this strategy may provide liquidity for (must exist on `UFloatSwapRouter`).
interface IUFloatStrategyAllowedTokens {
    function addAllowedToken(address token) external;

    function removeAllowedToken(address token) external;

    function isAllowedToken(address token) external view returns (bool);

    /// @notice Enumerate with `allowedTokenCount()` + `allowedTokens(i)`.
    function allowedTokens(uint256 index) external view returns (address);

    function allowedTokenCount() external view returns (uint256);
}
