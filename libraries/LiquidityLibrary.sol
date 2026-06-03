// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IUniswapV3Factory.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/INonfungiblePositionManager.sol";
import "../interfaces/IUniswapV3PoolMinimal.sol";
import "./TickMath.sol";

library LiquidityLibrary {
    using SafeERC20 for IERC20;
    
    // FixedPoint96 constants (from LiquidityAmounts)
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    
    // Structs
    struct PositionState {
        uint256 positionId;
        int24 tickLower;
        int24 tickUpper;
    }
    struct MintContext {
        INonfungiblePositionManager npm;
        IUniswapV3Factory factory;
        IUniswapV3PoolMinimal pool;
        address weth;
        address tokens;
        address assetPoolV3;
        uint24 fee;
        int24 tickSpacing; 
        int24 m;              // your width multiplier
        uint16 slippageBps;
        uint256 dust;         // min dust amount
    }
    struct IncreaseContext {
        INonfungiblePositionManager npm;
        IUniswapV3PoolMinimal pool;
        uint24 fee;
        uint16 slippageBps;
        uint256 dust;
    }
    struct DecreaseContext {
        INonfungiblePositionManager npm;
        IUniswapV3PoolMinimal pool;
    }
    
    // ============ TickAlignmentMath functions ============
    
    function alignDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        return r == 0 ? tick : (tick < 0 ? tick - r - spacing : tick - r);
    }

    function alignUp(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        return r == 0 ? tick : (tick < 0 ? tick - r : tick + (spacing - r));
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = y;
        z = (x + 1) >> 1;
        while (z < x) {
            x = z;
            z = (y / z + z) >> 1;
        }
        return x;
    }

    function sqrt1e18(uint256 x1e18) internal pure returns (uint256) {
        uint256 maxSafeX1e18 = type(uint256).max / 1e18;
        
        if (x1e18 > maxSafeX1e18) {
            uint256 sqrtX = sqrt(x1e18);
            // Check if sqrtX * 1e18 would overflow
            if (sqrtX > type(uint256).max / 1e18) {
                revert("sqrt1e18: result overflow");
            }
            return sqrtX * 1e18;
        }
        
        unchecked {
            return sqrt(x1e18 * 1e18);
        }
    }

    function getSqrtRatios(int24 lowerTick, int24 upperTick) internal pure returns (uint160 sqrtL, uint160 sqrtU) {
        sqrtL = TickMath.getSqrtRatioAtTick(lowerTick);
        sqrtU = TickMath.getSqrtRatioAtTick(upperTick);
    }

    function calculateMinAmounts(uint256 amount0, uint256 amount1, uint16 slippageBps) internal pure returns (uint256 min0, uint256 min1) {
        require(slippageBps <= 10_000, "slippageBps > 100%");
        
        uint256 slippage0 = Math.mulDiv(amount0, slippageBps, 10_000);
        uint256 slippage1 = Math.mulDiv(amount1, slippageBps, 10_000);

        min0 = slippage0 >= amount0 ? 0 : amount0 - slippage0;
        min1 = slippage1 >= amount1 ? 0 : amount1 - slippage1;
    }
    
    // ============ LiquidityAmounts functions ============
    
    /// @notice Downcasts uint256 to uint128
    function toUint128(uint256 x) private pure returns (uint128 y) {
        require((y = uint128(x)) == x);
    }

    function getLiquidityForAmount0(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96, 
        uint256 amount0
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = Math.mulDiv(sqrtRatioAX96, sqrtRatioBX96, Q96);
        return toUint128(Math.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function getLiquidityForAmount1(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return toUint128(Math.mulDiv(amount1, Q96, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            liquidity = getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtRatioX96, sqrtRatioBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioX96, amount1);

            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
        }
    }

    function getAmount0ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return
            Math.mulDiv(
                uint256(liquidity) << RESOLUTION,
                sqrtRatioBX96 - sqrtRatioAX96,
                sqrtRatioBX96
            ) / sqrtRatioAX96;
    }

    function getAmount1ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return Math.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96);
    }

    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }
    
    // ============ Position Management functions ============
    
    function getPositionLiquidity(
        PositionState storage ps,
        INonfungiblePositionManager npm
    ) internal view returns (uint128 liquidity) {
        if (ps.positionId == 0) return 0;
        (, , , , , , , liquidity, , , , ) = npm.positions(ps.positionId);
    }
    
    function getPositionData(
        PositionState storage ps,
        INonfungiblePositionManager npm
    )
        internal
        view
        returns (
            address token0,
            address token1,
            uint24 fee,
            int24 posTickLower,
            int24 posTickUpper,
            uint128 liquidity
        )
    {
        if (ps.positionId == 0) return (address(0), address(0), 0, 0, 0, 0);
        (, , token0, token1, fee, posTickLower, posTickUpper, liquidity, , , , ) =
            npm.positions(ps.positionId);
    }
    
    function mintNewPosition(
        PositionState storage ps,
        MintContext memory ctx,
        uint256 tokenBal,
        uint256 wethBal
    ) internal returns (uint256 newTokenId, uint128 newLiquidity) {
        if (tokenBal == 0 && wethBal == 0) return (ps.positionId, 0);

        // Recreate your existing Uniswap pool fetch & validation
        address poolAddr = ctx.factory.getPool(ctx.weth, ctx.tokens, ctx.fee);
        require(poolAddr == ctx.assetPoolV3, "Pool mismatch");

        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(poolAddr);
        address token0 = pool.token0();
        address token1 = pool.token1();

        require(
            (token0 == ctx.weth && token1 == ctx.tokens) ||
            (token0 == ctx.tokens && token1 == ctx.weth),
            "Pool token mismatch"
        );
        ( , int24 currentTick, , , , , ) = pool.slot0();
        int24 base = alignDown(currentTick, ctx.tickSpacing);
        int24 total = int24(int256(ctx.m) * int256(ctx.tickSpacing));
        require(total > 0, "width=0");
        int24 lower;
        int24 upper;
        if (ctx.m % 2 == 0) {
            lower = base - (ctx.m / 2) * ctx.tickSpacing; 
            upper = base + (ctx.m / 2) * ctx.tickSpacing;
        } else {
            lower = base - ((ctx.m - 1) / 2) * ctx.tickSpacing;
            upper = lower + total;
        }
        int24 minTick = alignUp(TickMath.MIN_TICK, ctx.tickSpacing);
        int24 maxTick = alignDown(TickMath.MAX_TICK, ctx.tickSpacing);

        if (lower < minTick) lower = minTick;
        if (upper > maxTick) upper = maxTick;
        if (lower >= upper) {
            lower -= ctx.tickSpacing;
            upper += ctx.tickSpacing;
        }
        require(lower < upper, "bad ticks");
        ps.tickLower = lower;
        ps.tickUpper = upper;
        uint160 sqrtP;
        (sqrtP, , , , , , ) = pool.slot0();
        (uint160 sqrtL, uint160 sqrtU) = getSqrtRatios(ps.tickLower, ps.tickUpper);
        uint256 bal0;
        uint256 bal1;
        if (token0 == ctx.weth) {
            bal0 = wethBal;
            bal1 = tokenBal;
        } else {
            bal0 = tokenBal;
            bal1 = wethBal;
        }
        uint128 liq = getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, bal0, bal1);
        require(liq > 0, "no liq");
        (uint256 need0, uint256 need1) = getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liq);
        if (need0 > bal0) need0 = bal0;
        if (need1 > bal1) need1 = bal1;
        (uint256 min0, uint256 min1) = calculateMinAmounts(need0, need1, ctx.slippageBps);
        INonfungiblePositionManager.MintParams memory params =
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: ctx.fee,
                tickLower: ps.tickLower,
                tickUpper: ps.tickUpper,
                amount0Desired: need0,
                amount0Min: min0,
                amount1Desired: need1,
                amount1Min: min1,
                recipient: address(this),
                deadline: block.timestamp + 300
            });
        (uint256 tokenId, uint128 liquidity, , ) = ctx.npm.mint(params);

        ps.positionId = tokenId;
        newTokenId = tokenId;
        newLiquidity = liquidity;
    }

    function mintNewPositionWithRange(
        PositionState storage ps,
        MintContext memory ctx,
        uint256 tokenBal,
        uint256 wethBal,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (uint256 newTokenId, uint128 newLiquidity) {
        if (tokenBal == 0 && wethBal == 0) return (ps.positionId, 0);

        address poolAddr = ctx.factory.getPool(ctx.weth, ctx.tokens, ctx.fee);
        require(poolAddr == ctx.assetPoolV3, "Pool mismatch");

        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(poolAddr);
        address token0 = pool.token0();
        address token1 = pool.token1();

        require(
            (token0 == ctx.weth && token1 == ctx.tokens) ||
            (token0 == ctx.tokens && token1 == ctx.weth),
            "Pool token mismatch"
        );

        int24 minTick = alignUp(TickMath.MIN_TICK, ctx.tickSpacing);
        int24 maxTick = alignDown(TickMath.MAX_TICK, ctx.tickSpacing);
        int24 lower = tickLower;
        int24 upper = tickUpper;
        if (lower < minTick) lower = minTick;
        if (upper > maxTick) upper = maxTick;
        if (lower >= upper) upper = lower + ctx.tickSpacing;
        require(lower < upper, "bad ticks");
        ps.tickLower = lower;
        ps.tickUpper = upper;

        uint160 sqrtP;
        (sqrtP, , , , , , ) = pool.slot0();
        (uint160 sqrtL, uint160 sqrtU) = getSqrtRatios(ps.tickLower, ps.tickUpper);
        uint256 bal0;
        uint256 bal1;
        if (token0 == ctx.weth) {
            bal0 = wethBal;
            bal1 = tokenBal;
        } else {
            bal0 = tokenBal;
            bal1 = wethBal;
        }
        uint128 liq = getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, bal0, bal1);
        require(liq > 0, "no liq");
        (uint256 need0, uint256 need1) = getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liq);
        if (need0 > bal0) need0 = bal0;
        if (need1 > bal1) need1 = bal1;
        (uint256 min0, uint256 min1) = calculateMinAmounts(need0, need1, ctx.slippageBps);
        INonfungiblePositionManager.MintParams memory params =
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: ctx.fee,
                tickLower: ps.tickLower,
                tickUpper: ps.tickUpper,
                amount0Desired: need0,
                amount0Min: min0,
                amount1Desired: need1,
                amount1Min: min1,
                recipient: address(this),
                deadline: block.timestamp + 300
            });
        (uint256 tokenId, uint128 liquidity, , ) = ctx.npm.mint(params);

        ps.positionId = tokenId;
        newTokenId = tokenId;
        newLiquidity = liquidity;
    }
    
    function increaseLiquidityInternal(
        PositionState storage ps,
        IncreaseContext memory ctx,
        IERC20 token0,
        IERC20 token1
    ) internal returns (uint128 addedLiquidity) {
        if (ps.positionId == 0) return 0;

        (
            address posToken0,
            address posToken1,
            uint24 fee,
            int24 _tickLower,
            int24 _tickUpper,
            uint128 currLiq
        ) = getPositionData(ps, ctx.npm);
        require(fee == ctx.fee, "wrong fee tier");
        require(address(token0) == posToken0 && address(token1) == posToken1, "token mismatch");
        uint160 sqrtP;
        (sqrtP, , , , , , ) = ctx.pool.slot0();
        (uint160 sqrtL, uint160 sqrtU) = getSqrtRatios(_tickLower, _tickUpper);
        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        if (bal0 < ctx.dust && bal1 < ctx.dust) return 0;
        uint128 liq = getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, bal0, bal1);
        if (liq == 0) return 0;
        (uint256 need0, uint256 need1) = getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liq);
        if (need0 > bal0) need0 = bal0;
        if (need1 > bal1) need1 = bal1;
        (uint256 min0, uint256 min1) = calculateMinAmounts(need0, need1, ctx.slippageBps);
        unchecked {
            require(uint256(currLiq) + uint256(liq) <= type(uint128).max, "liquidity overflow");
        }
        INonfungiblePositionManager.IncreaseLiquidityParams memory p =
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: ps.positionId,
                amount0Desired: need0,
                amount1Desired: need1,
                amount0Min: min0,
                amount1Min: min1,
                deadline: block.timestamp + 1200
            });
        (uint128 liqAdded,,) = ctx.npm.increaseLiquidity(p);
        addedLiquidity = liqAdded;
    }
    
    function decreaseAllLiquidity(
        PositionState storage ps,
        DecreaseContext memory ctx
    ) internal returns (uint128 totalRemoved) {
        if (ps.positionId == 0) return 0;
        uint128 liq = getPositionLiquidity(ps, ctx.npm);
        if (liq == 0) {
            return 0;
        }
        while (liq > 0) {
            INonfungiblePositionManager.DecreaseLiquidityParams memory p =
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: ps.positionId,
                    liquidity: liq,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 300
                });
            ctx.npm.decreaseLiquidity(p);
            totalRemoved += liq;
            liq = getPositionLiquidity(ps, ctx.npm);
        }
    }
    
    function decreaseLiquidityByAmount(
        PositionState storage ps,
        DecreaseContext memory ctx,
        uint128 liqToRemove
    ) internal returns (uint128 removed) {
        if (ps.positionId == 0) return 0;
        if (liqToRemove == 0) return 0;

        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: ps.positionId,
                liquidity: liqToRemove,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 300
            });

        ctx.npm.decreaseLiquidity(params);
        removed = liqToRemove;
    }

    /// @notice token1/token0 price increase from `anchorTick` to `currentTick` in bps (10_000 = 100%), when current is above anchor; else 0.
    function priceDeviationBpsAbove(int24 anchorTick, int24 currentTick) internal pure returns (uint256 deviationBps) {
        if (currentTick <= anchorTick) return 0;
        uint160 sa = TickMath.getSqrtRatioAtTick(anchorTick);
        uint160 sc = TickMath.getSqrtRatioAtTick(currentTick);
        uint256 sa2 = uint256(sa) * uint256(sa);
        uint256 sc2 = uint256(sc) * uint256(sc);
        uint256 priceRatio1e18 = Math.mulDiv(sc2, 1e18, sa2);
        if (priceRatio1e18 <= 1e18) return 0;
        return Math.mulDiv(priceRatio1e18 - 1e18, 10000, 1e18);
    }

    /// @notice Trailing-floor depth below current price (bps). E.g. num/den = 1/3 => 3% rally vs baseline => ~1% pullback band under spot.
    function trailingFloorDepthBps(uint256 rallyBps, uint32 num, uint32 den) internal pure returns (uint256 depthBps) {
        if (den == 0) return 0;
        return Math.mulDiv(rallyBps, uint256(num), uint256(den));
    }

    /// @notice Tick at or below the sqrt price that is `depthBps`/10000 below the current token1/token0 price (0 < depthBps < 10_000).
    function floorTickBelowCurrentByBps(int24 currentTick, uint256 depthBps) internal pure returns (int24) {
        if (depthBps == 0) return currentTick;
        if (depthBps >= 10000) depthBps = 9999;
        uint160 sc = TickMath.getSqrtRatioAtTick(currentTick);
        uint256 priceFactor1e18 = Math.mulDiv(10000 - depthBps, 1e18, 10000);
        uint256 sqrtScale1e18 = sqrt1e18(priceFactor1e18);
        uint256 newSqrt256 = Math.mulDiv(uint256(sc), sqrtScale1e18, 1e18);
        if (newSqrt256 <= uint256(TickMath.MIN_SQRT_RATIO)) {
            return TickMath.MIN_TICK;
        }
        if (newSqrt256 >= uint256(TickMath.MAX_SQRT_RATIO)) {
            newSqrt256 = uint256(TickMath.MAX_SQRT_RATIO) - 1;
        }
        return TickMath.getTickAtSqrtRatio(uint160(newSqrt256));
    }
}
