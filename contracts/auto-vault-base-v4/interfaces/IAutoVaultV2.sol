// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IAutoVault.sol";

/// @notice AutoVaultV2 extensions for strategy reserve parking during LP increase.
interface IAutoVaultV2 is IAutoVault {
    /// @notice Return tokens held for the strategy (only callable by the vault's strategy).
    function strategyPull(address token, uint256 amount) external;
}
