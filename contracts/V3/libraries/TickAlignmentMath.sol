// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TickMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

library TickAlignmentMath {
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
}

