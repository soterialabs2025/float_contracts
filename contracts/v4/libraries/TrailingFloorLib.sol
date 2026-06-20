// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "../../../libraries/TickMath.sol";

/// @title TrailingFloorLib
/// @notice Pure tick / trailing-floor math used by `FloatStrategyV4` only (no dependency on `LiquidityLibrary`).
library TrailingFloorLib {
    error SqrtOverflow();

    function alignDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        return r == 0 ? tick : (tick < 0 ? tick - r - spacing : tick - r);
    }

    function alignUp(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        return r == 0 ? tick : (tick < 0 ? tick - r : tick + (spacing - r));
    }

    function sqrt(uint256 y) private pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = y;
        z = (x + 1) >> 1;
        while (z < x) {
            x = z;
            z = (y / z + z) >> 1;
        }
        return x;
    }

    function sqrt1e18(uint256 x1e18) private pure returns (uint256) {
        uint256 maxSafeX1e18 = type(uint256).max / 1e18;
        if (x1e18 > maxSafeX1e18) {
            uint256 sqrtX = sqrt(x1e18);
            if (sqrtX > type(uint256).max / 1e18) revert SqrtOverflow();
            return sqrtX * 1e18;
        }
        unchecked {
            return sqrt(x1e18 * 1e18);
        }
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
        return Math.mulDiv(priceRatio1e18 - 1e18, 10_000, 1e18);
    }

    function trailingFloorDepthBps(uint256 rallyBps, uint32 num, uint32 den) internal pure returns (uint256 depthBps) {
        if (den == 0) return 0;
        return Math.mulDiv(rallyBps, uint256(num), uint256(den));
    }

    /// @notice Tick at or below the sqrt price that is `depthBps`/10000 below the current token1/token0 price (0 < depthBps < 10_000).
    function floorTickBelowCurrentByBps(int24 currentTick, uint256 depthBps) internal pure returns (int24) {
        if (depthBps == 0) return currentTick;
        if (depthBps >= 10_000) depthBps = 9999;
        uint160 sc = TickMath.getSqrtRatioAtTick(currentTick);
        uint256 priceFactor1e18 = Math.mulDiv(10_000 - depthBps, 1e18, 10_000);
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

    /// @notice Tick at or above the sqrt price that is `riseBps`/10000 above the current token1/token0 price (0 < riseBps < 10_000).
    function ceilTickAboveCurrentByBps(int24 currentTick, uint256 riseBps) internal pure returns (int24) {
        if (riseBps == 0) return currentTick;
        if (riseBps >= 10_000) riseBps = 9999;
        uint160 sc = TickMath.getSqrtRatioAtTick(currentTick);
        uint256 priceFactor1e18 = Math.mulDiv(10_000 + riseBps, 1e18, 10_000);
        uint256 sqrtScale1e18 = sqrt1e18(priceFactor1e18);
        uint256 newSqrt256 = Math.mulDiv(uint256(sc), sqrtScale1e18, 1e18);
        if (newSqrt256 <= uint256(TickMath.MIN_SQRT_RATIO)) {
            newSqrt256 = uint256(TickMath.MIN_SQRT_RATIO) + 1;
        }
        if (newSqrt256 >= uint256(TickMath.MAX_SQRT_RATIO)) {
            return TickMath.MAX_TICK;
        }
        return TickMath.getTickAtSqrtRatio(uint160(newSqrt256));
    }
}
