
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./INonfungiblePositionManager.sol";
import "./IUniswapV3PoolMinimal.sol";
import "../libraries/LiquidityLibrary.sol";

interface IPositionManager {
    struct MintResult {
        uint256 positionId;
        uint128 liquidity;
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
    }
    
    struct CollectResult {
        uint256 amount0;
        uint256 amount1;
    }
    
    function mintNewPosition(
        LiquidityLibrary.MintContext memory ctx,
        uint256 termBal,
        uint256 wethBal
    ) external returns (MintResult memory);
    
    function increaseLiquidity(
        LiquidityLibrary.IncreaseContext memory ctx,
        uint256 positionId,
        int24 tickLower,
        int24 tickUpper,
        address token0,
        address token1
    ) external returns (uint128);
    
    function decreaseAllLiquidity(
        LiquidityLibrary.DecreaseContext memory ctx,
        uint256 positionId,
        int24 tickLower,
        int24 tickUpper
    ) external returns (uint128);
    
    function decreaseLiquidityByAmount(
        LiquidityLibrary.DecreaseContext memory ctx,
        uint256 positionId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityToRemove
    ) external returns (uint128);
    
    function collectAllFees(
        INonfungiblePositionManager npm,
        uint256 positionId,
        address recipient
    ) external returns (CollectResult memory);
    
    function getPositionLiquidity(
        INonfungiblePositionManager npm,
        uint256 positionId
    ) external view returns (uint128);
    
    function balanceOfPool(
        IUniswapV3PoolMinimal pool,
        INonfungiblePositionManager npm,
        uint256 positionId,
        int24 tickLower,
        int24 tickUpper,
        address wethAddr
    ) external view returns (uint256 termsAmt, uint256 wethAmt);
    
    function balanceOfPoolWithSqrt(
        IUniswapV3PoolMinimal pool,
        INonfungiblePositionManager npm,
        uint256 positionId,
        int24 tickLower,
        int24 tickUpper,
        address wethAddr,
        uint160 sqrtPriceX96
    ) external view returns (uint256 termsAmt, uint256 wethAmt);
    
    function calculateLiquidityToRemove(
        IUniswapV3PoolMinimal pool,
        INonfungiblePositionManager npm,
        uint256 positionId,
        int24 tickLower,
        int24 tickUpper,
        address wethAddr,
        uint256 amount,
        uint256 spotPrice1e18
    ) external view returns (uint256);
}