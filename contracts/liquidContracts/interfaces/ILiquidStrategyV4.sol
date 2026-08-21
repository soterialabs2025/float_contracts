// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Vault-facing API for minimal liquid strategies on Uniswap v4 (no LP positions).
interface ILiquidStrategyV4 {
    function assetAddr() external view returns (address);

    function beforeDeposit() external;
    function deposit(uint256 amount) external;
    function vaultValue() external view returns (uint256);
    function withdraw(uint256 userShares, uint256 totalSupply, address receiver) external;
    /// @dev PoolKey is read from this contract's seeded `v4PoolConfig` (`getV4PoolConfig` / constructor seed).
    function changeAsset(address _newAssetAddr) external;
}
