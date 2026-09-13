// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LiquidityLibraryV2} from "../contracts/auto-vaults-rh-v3/libraries/LiquidityLibraryV2.sol";
import {TickMath} from "../contracts/auto-vaults-rh-v3/libraries/TickMath.sol";

/// @dev Same property as `BandShareRhV4Test`, for the V3 library. RhV3's asset is token0 (its address sorts below
///      aeWETH), which is the orientation the other stacks do not exercise.
contract BandShareRhV3Test is Test {
    uint256 internal constant ONE = 1e18;

    function _referenceShare0(int24 lower, int24 upper, int24 current) internal pure returns (uint256) {
        uint256 sqrtP = TickMath.getSqrtRatioAtTick(current);
        uint256 sqrtL = TickMath.getSqrtRatioAtTick(lower);
        uint256 sqrtU = TickMath.getSqrtRatioAtTick(upper);
        uint256 w0 = ((sqrtU - sqrtP) * ONE / sqrtU) * sqrtP / (1 << 96);
        uint256 w1 = (sqrtP - sqrtL) * ONE / (1 << 96);
        return w0 * ONE / (w0 + w1);
    }

    function test_SymmetricBandIsHalfAndHalf() public pure {
        // ±1200 around a spacing-200 tick, the live RhV3 shape.
        assertApproxEqAbs(LiquidityLibraryV2.mintShare(-101_200, -98_800, -100_000, true), ONE / 2, 1e12);
        assertApproxEqAbs(LiquidityLibraryV2.mintShare(-101_200, -98_800, -100_000, false), ONE / 2, 1e12);
    }

    function test_SpacingSnapMovesTheSplit() public pure {
        // A tick 180 above the aligned base with spacing 200: the band is centred on the base, not the tick, so
        // the position wants less token0 than an exactly centred band would.
        uint256 centred = LiquidityLibraryV2.mintShare(-101_200, -98_800, -100_000, true);
        uint256 snapped = LiquidityLibraryV2.mintShare(-101_200, -98_800, -99_820, true);
        assertLt(snapped, centred, "tick above centre wants less token0");
        assertGt(centred - snapped, ONE / 50, "and the gap is material, not rounding");
    }

    function test_AssetAsToken0FollowsRangeAbove() public pure {
        // Asset is token0. More room above means more asset is wanted.
        uint256 wideAbove = LiquidityLibraryV2.mintShare(-100_600, -98_200, -100_000, true);
        uint256 wideBelow = LiquidityLibraryV2.mintShare(-101_800, -99_400, -100_000, true);
        assertGt(wideAbove, ONE / 2);
        assertLt(wideBelow, ONE / 2);
        assertApproxEqAbs(wideAbove, _referenceShare0(-100_600, -98_200, -100_000), 1e12);
    }

    function test_OutsideBandIsSingleSided() public pure {
        assertEq(LiquidityLibraryV2.mintShare(100, 200, 100, true), ONE);
        assertEq(LiquidityLibraryV2.mintShare(100, 200, 200, true), 0);
        assertEq(LiquidityLibraryV2.mintShare(100, 200, 50, false), 0);
        assertEq(LiquidityLibraryV2.mintShare(100, 200, 300, false), ONE);
    }

    function testFuzz_MatchesReferenceAndIsBounded(int24 lower, int24 width, int24 offset) public pure {
        lower = int24(bound(int256(lower), -200_000, 200_000));
        width = int24(bound(int256(width), 10, 40_000));
        offset = int24(bound(int256(offset), 1, int256(width) - 1));
        int24 upper = lower + width;
        int24 current = lower + offset;
        uint256 s0 = LiquidityLibraryV2.mintShare(lower, upper, current, true);
        uint256 s1 = LiquidityLibraryV2.mintShare(lower, upper, current, false);
        assertEq(s0 + s1, ONE, "the two legs account for everything");
        assertApproxEqRel(s0 + 1, _referenceShare0(lower, upper, current) + 1, 1e12, "matches the formula");
    }
}
