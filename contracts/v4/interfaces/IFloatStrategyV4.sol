// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../libraries/LiquidityLibraryV4.sol";

/// @title IFloatStrategyV4
/// @notice Float vault ↔ strategy surface for the Uniswap v4 stack only (not ABI-compatible with `IFloatStrategy`).
interface IFloatStrategyV4 {
    function UniswapFeesCollected() external view returns (uint256);

    function enterNeutralFromVault() external;
    function resumeNormalFromVault() external;

    function getPositionId() external view returns (uint256);
    function beforeDeposit() external;
    function deposit(uint256 amount) external;
    function poolValue() external view returns (uint256);
    function withdraw(uint256 userShares, uint256 totalSupply, address receiver) external;
    function readInRange() external view returns (bool);
    function balanceOfIdle() external view returns (uint256);
    function balanceOfPool() external view returns (uint256 tokenAmt, uint256 wethAmt);

    /// @notice Switch ASSET and Uniswap v4 pool identity to `(_newAssetAddr, key)`.
    /// @dev    `key` must be the canonical PoolKey (currency0 < currency1) for the ASSET/WETH pool. `hookData`
    ///         is **not** passed here — it is registered with the swap router by `FloatContractManagerV4` before
    ///         this call so that the strategy's `_swap` lookups already resolve to the new pool.
    /// @param _newAssetAddr Non-WETH side of the pool — strategy's new ASSET.
    /// @param key           Pre-validated PoolKey for the ASSET/WETH pool to rotate into.
    function changeAsset(
        address _newAssetAddr,
        LiquidityLibraryV4.PoolKey calldata key
    ) external;

    function totalLiquidity() external view returns (uint128);
}
