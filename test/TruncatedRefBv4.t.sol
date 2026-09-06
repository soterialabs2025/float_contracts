// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SwapGateLib} from "../contracts/auto-vault-base-v4/libraries/SwapGateLib.sol";
import {AutoStrategyManagerBv4} from "../contracts/auto-vault-base-v4/AutoStrategyManagerBv4.sol";

contract RefManagerHarness is AutoStrategyManagerBv4 {}

/// @dev The truncated price reference. `refTick` is written on a keeper cadence and clamped every time, so the
///      price the vault mints against and the price the swap gate measures against can only move as fast as
///      elapsed time allows. This is Uniswap's truncated oracle idea without the hook: hooks are fixed in the
///      PoolKey and cannot be attached to an existing pool, and `TruncGeoOracle` additionally demands a zero-fee,
///      full-range, liquidity-locked pool, which an active LP strategy cannot be.
contract TruncatedRefBv4Test is Test {
    /// @dev Defaults: half a tick per second, capped at 2,000 ticks of drift.
    uint256 internal constant SEC_PER_TICK = 2;
    uint256 internal constant MAX_DRIFT = 2_000;
    /// @dev Base block time. One block of manipulation should buy an attacker almost nothing.
    uint256 internal constant BLOCK_TIME = 2;

    RefManagerHarness internal m;

    function setUp() public {
        m = new RefManagerHarness();
        // Far enough in that a 30-day-old reference is still a valid timestamp.
        vm.warp(100_000_000);
        vm.roll(100);
    }

    function _drift(uint256 age) internal view returns (uint256) {
        return SwapGateLib.refDrift(uint64(block.timestamp - age), SEC_PER_TICK, MAX_DRIFT);
    }

    // --- drift is earned in time, not in blocks ---

    function test_DriftIsHalfATickPerSecond() public view {
        assertEq(_drift(0), 0);
        assertEq(_drift(BLOCK_TIME), 1, "one Base block buys one tick");
        assertEq(_drift(5 minutes), 150, "the keeper cadence buys 150 ticks, about 1.5%");
        assertEq(_drift(30 minutes), 900);
        assertEq(_drift(1 hours), 1_800);
    }

    /// @dev The cap is what stops a neglected reference relaxing until it bounds nothing at all.
    function test_DriftIsCapped() public view {
        assertEq(_drift(4_000), MAX_DRIFT, "cap binds at ~67 minutes of silence");
        assertEq(_drift(30 days), MAX_DRIFT);
    }

    /// @dev Unseeded and misconfigured both yield no allowance rather than an unbounded one.
    function test_DriftIsZeroWhenUnseededOrRateless() public view {
        assertEq(SwapGateLib.refDrift(0, SEC_PER_TICK, MAX_DRIFT), 0, "never written");
        assertEq(SwapGateLib.refDrift(uint64(block.timestamp - 1 hours), 0, MAX_DRIFT), 0, "zero rate");
    }

    function test_DriftIsZeroForAFutureTimestamp() public view {
        assertEq(SwapGateLib.refDrift(uint64(block.timestamp + 1 days), SEC_PER_TICK, MAX_DRIFT), 0);
    }

    // --- the clamp ---

    function test_ClampPassesThroughInsideTheBand() public pure {
        assertEq(SwapGateLib.clampTick(100, 0, 150), 100);
        assertEq(SwapGateLib.clampTick(-100, 0, 150), -100);
        assertEq(SwapGateLib.clampTick(150, 0, 150), 150, "boundary is inclusive");
    }

    function test_ClampTruncatesBothDirections() public pure {
        assertEq(SwapGateLib.clampTick(5_000, 0, 150), 150);
        assertEq(SwapGateLib.clampTick(-5_000, 0, 150), -150);
    }

    function test_ClampIsRelativeToTheReferenceNotZero() public pure {
        assertEq(SwapGateLib.clampTick(5_000, 1_000, 150), 1_150);
        assertEq(SwapGateLib.clampTick(-5_000, -1_000, 150), -1_150);
    }

    /// @dev A zero allowance pins the reference exactly, which is what a same-second write should get.
    function test_ZeroDriftPinsTheReference() public pure {
        assertEq(SwapGateLib.clampTick(50_000, 700, 0), 700);
    }

    function test_ClampStaysInsideUsableTickRange() public pure {
        assertEq(SwapGateLib.clampTick(887_272, 887_000, 5_000), 887_272, "cannot exceed MAX_TICK");
        assertEq(SwapGateLib.clampTick(-887_272, -887_000, 5_000), -887_272, "cannot exceed MIN_TICK");
    }

    // --- what an attacker gets for a block of manipulation ---

    /// @dev The security claim, stated directly. Slamming the pool 50% away and catching the very next keeper
    ///      write moves the reference by a single tick.
    function test_OneBlockOfManipulationMovesTheReferenceOneTick() public view {
        int24 manipulated = 4_055; // ~1.50x
        int24 next = SwapGateLib.nextRefTick(
            manipulated, 0, uint64(block.timestamp - BLOCK_TIME), SEC_PER_TICK, MAX_DRIFT
        );
        assertEq(next, 1);
    }

    /// @dev To move it materially the manipulation has to be held, which is the whole economic argument: half an
    ///      hour of sustained pressure against arbitrage buys 9.4%.
    function test_SustainedManipulationMovesItSlowly() public view {
        int24 manipulated = 4_055;
        assertEq(
            SwapGateLib.nextRefTick(manipulated, 0, uint64(block.timestamp - 5 minutes), SEC_PER_TICK, MAX_DRIFT),
            150
        );
        assertEq(
            SwapGateLib.nextRefTick(manipulated, 0, uint64(block.timestamp - 30 minutes), SEC_PER_TICK, MAX_DRIFT),
            900
        );
    }

    /// @dev A genuine move is not resisted forever: once the reference has had time, it adopts the real price.
    function test_GenuineMoveIsTrackedOnceTimePasses() public view {
        int24 real = 900;
        assertEq(
            SwapGateLib.nextRefTick(real, 0, uint64(block.timestamp - 30 minutes), SEC_PER_TICK, MAX_DRIFT),
            real,
            "inside the allowance, so adopted exactly"
        );
    }

    /// @dev The first write has nothing to clamp against and takes spot, which is why `_mintPosition` seeds it.
    function test_UnseededReferenceAdoptsSpot() public view {
        assertEq(SwapGateLib.nextRefTick(50_000, 0, 0, SEC_PER_TICK, MAX_DRIFT), 50_000);
    }

    // --- pricing off the reference ---

    function test_RefPriceIsZeroUntilSeeded() public view {
        assertEq(SwapGateLib.refPrice1e18(1_000, 1_000, 0, SEC_PER_TICK, MAX_DRIFT, true), 0);
    }

    /// @dev The price the vault mints against is the clamped tick's price, not spot's.
    function test_RefPriceUsesTheClampedTick() public view {
        uint64 refTime = uint64(block.timestamp - BLOCK_TIME);
        uint256 got = SwapGateLib.refPrice1e18(4_055, 0, refTime, SEC_PER_TICK, MAX_DRIFT, true);

        assertEq(got, SwapGateLib.priceAtTick(1, true), "priced at the clamp, one tick from the reference");
        assertApproxEqRel(got, SwapGateLib.priceAtTick(0, true), 1e15, "within 0.1% of the reference");
        // Spot was 1.5x away and the reference did not follow it.
        assertGt(SwapGateLib.priceAtTick(4_055, true), (got * 14) / 10);
    }

    /// @dev With enough elapsed time the clamp stops binding and the reference price converges on spot. This is
    ///      the degradation path: a neglected feed relaxes toward spot pricing instead of blocking deposits.
    function test_RefPriceConvergesOnSpotWhenStale() public view {
        int24 spot = 1_500;
        uint256 stale = SwapGateLib.refPrice1e18(
            spot, 0, uint64(block.timestamp - 1 hours), SEC_PER_TICK, MAX_DRIFT, true
        );
        assertEq(stale, SwapGateLib.priceAtTick(spot, true), "1,800 ticks of drift covers a 1,500 tick gap");
    }

    /// @dev Price direction follows currency ordering, same as `quoteAtSqrt`.
    function test_RefPriceInvertsWithCurrencyOrder() public view {
        uint64 refTime = uint64(block.timestamp - 1 hours);
        uint256 a = SwapGateLib.refPrice1e18(500, 500, refTime, SEC_PER_TICK, MAX_DRIFT, true);
        uint256 b = SwapGateLib.refPrice1e18(500, 500, refTime, SEC_PER_TICK, MAX_DRIFT, false);
        assertGt(a, b);
        assertApproxEqRel(a * b, uint256(1e18) * 1e18, 1e12);
    }

    // --- manager settings ---

    function test_DefaultsMatchTheFiveMinuteFeed() public view {
        assertEq(m.secondsPerRefTick(), 2);
        assertEq(m.maxRefDrift(), 2_000);
        assertEq(m.minRefUpdateInterval(), 5 minutes);
    }

    /// @dev Zero would let one write adopt any price at all, defeating the entire mechanism.
    function test_SecondsPerRefTickCannotBeZero() public {
        vm.expectRevert(AutoStrategyManagerBv4.RefConfig.selector);
        m.setSecondsPerRefTick(0);
    }

    function test_MaxRefDriftIsCappedAtTheTickRange() public {
        vm.expectRevert(AutoStrategyManagerBv4.RefConfig.selector);
        m.setMaxRefDrift(887_273);
        m.setMaxRefDrift(887_272);
        assertEq(m.maxRefDrift(), 887_272);
    }

    function test_RefSettingsAreOwnerOnly() public {
        vm.prank(address(0xBADD));
        vm.expectRevert();
        m.setSecondsPerRefTick(10);
    }

    /// @dev The swap gate now anchors on the reference, so its bound no longer has to clear a full band exit.
    function test_SwapTickDeviationTightenedBelowBandWidth() public view {
        assertEq(m.maxSwapTickDeviation(), 1_000);
        assertLt(m.maxSwapTickDeviation(), m.rangeAboveTicks() + m.innerAboveTicks());
    }
}
