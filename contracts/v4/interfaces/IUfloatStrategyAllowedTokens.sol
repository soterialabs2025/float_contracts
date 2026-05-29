// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IUfloatStrategyAllowedTokens
/// @notice Owner-managed allowlist of asset tokens this strategy may provide liquidity for (must exist on `UfloatSwapRouter`).
interface IUfloatStrategyAllowedTokens {
    function addAllowedToken(address token) external;

    function removeAllowedToken(address token) external;

    function isAllowedToken(address token) external view returns (bool);

    function allowedTokenCount() external view returns (uint256);
}
