// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LiquidityLibraryV4} from "../contracts/auto-vault-rh-v4/libraries/LiquidityLibraryV4.sol";
import {TickMath} from "../contracts/v4/libraries/TickMath.sol";

/// @dev The mint ratio is a property of the band, not a setting. A symmetric band around the current tick takes the
///      two legs in equal value; move the band, or the tick inside it, and the split moves with it. Balancing
///      inventory to anything else strands the difference — on Bv4 that was 43% of NAV — so the pre-mint swap must
///      aim at this number and nothing else.
contract BandShareRhV4Test is Test {
    uint256 internal constant ONE = 1e18;

    /// @dev Reference computation straight from the position formulas, in 1e18 fixed point, for comparison.
    ///      value0 = amount0 * P, amount0 = (√Pu − √P) / (√P √Pu), amount1 = √P − √Pl, per unit liquidity.
    function _referenceShare0(int24 lower, int24 upper, int24 current) internal pure returns (uint256) {
        uint256 sqrtP = TickMath.getSqrtRatioAtTick(current);
        uint256 sqrtL = TickMath.getSqrtRatioAtTick(lower);
        uint256 sqrtU = TickMath.getSqrtRatioAtTick(upper);
        // Scale everything to 1e18 relative to Q96 before combining, to keep the reference independent of mulDiv.
        uint256 w0 = ((sqrtU - sqrtP) * ONE / sqrtU) * sqrtP / (1 << 96);
        uint256 w1 = (sqrtP - sqrtL) * ONE / (1 << 96);
        return w0 * ONE / (w0 + w1);
    }

    function test_SymmetricBandIsHalfAndHalf() public pure {
        // ±1260 around the tick, the live RhV4 shape; spacing-aligned ticks.
        uint256 s = LiquidityLibraryV4.mintShare(126_720, 129_240, 127_980, false);
        assertApproxEqAbs(s, ONE / 2, 1e12, "symmetric band should split value evenly");
        // Orientation only flips which leg is called the asset.
        assertApproxEqAbs(LiquidityLibraryV4.mintShare(126_720, 129_240, 127_980, true), ONE / 2, 1e12);
    }

    function test_WiderRangeAboveWantsMoreCurrency0() public pure {
        // Asset is currency1 here (native ETH pool). Twice the room above means the position holds more of the
        // leg it sells on the way up, currency0, so the asset share drops below half.
        uint256 assetShare = LiquidityLibraryV4.mintShare(127_980 - 600, 127_980 + 1800, 127_980, false);
        assertLt(assetShare, ONE / 2, "more range above -> less currency1");
        assertApproxEqAbs(assetShare, ONE - _referenceShare0(127_980 - 600, 127_980 + 1800, 127_980), 1e12);
    }

    function test_WiderRangeBelowWantsMoreCurrency1() public pure {
        uint256 assetShare = LiquidityLibraryV4.mintShare(127_980 - 1800, 127_980 + 600, 127_980, false);
        assertGt(assetShare, ONE / 2, "more range below -> more currency1");
        assertApproxEqAbs(assetShare, ONE - _referenceShare0(127_980 - 1800, 127_980 + 600, 127_980), 1e12);
    }

    function test_TickDriftInsideBandMovesTheSplit() public pure {
        // Same band, tick drifted 375 up (this morning's RhV4 state). Less room above -> less currency0 wanted.
        uint256 centred = LiquidityLibraryV4.mintShare(126_720, 129_240, 127_980, false);
        uint256 drifted = LiquidityLibraryV4.mintShare(126_720, 129_240, 128_355, false);
        assertGt(drifted, centred, "tick above centre wants more currency1");
    }

    function test_OutsideBandIsSingleSided() public pure {
        assertEq(LiquidityLibraryV4.mintShare(100, 200, 100, true), ONE, "at lower: all currency0");
        assertEq(LiquidityLibraryV4.mintShare(100, 200, 50, true), ONE, "below lower: all currency0");
        assertEq(LiquidityLibraryV4.mintShare(100, 200, 200, true), 0, "at upper: all currency1");
        assertEq(LiquidityLibraryV4.mintShare(100, 200, 300, true), 0, "above upper: all currency1");
        assertEq(LiquidityLibraryV4.mintShare(100, 200, 50, false), 0, "asset is currency1, below lower: none");
    }

    function testFuzz_MatchesReferenceAndIsBounded(int24 lower, int24 width, int24 offset) public pure {
        // Kept to the tick range where the plain-integer reference above still has precision to compare against.
        lower = int24(bound(int256(lower), -200_000, 200_000));
        width = int24(bound(int256(width), 10, 40_000));
        offset = int24(bound(int256(offset), 1, int256(width) - 1));
        int24 upper = lower + width;
        int24 current = lower + offset;
        uint256 s0 = LiquidityLibraryV4.mintShare(lower, upper, current, true);
        uint256 s1 = LiquidityLibraryV4.mintShare(lower, upper, current, false);
        assertLe(s0, ONE);
        assertEq(s0 + s1, ONE, "the two legs account for everything");
        assertApproxEqRel(s0 + 1, _referenceShare0(lower, upper, current) + 1, 1e12, "matches the formula");
    }
}
