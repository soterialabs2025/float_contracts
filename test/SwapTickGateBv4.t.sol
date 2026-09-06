// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SwapGateLib} from "../contracts/auto-vault-base-v4/libraries/SwapGateLib.sol";
import {AutoStrategyManagerBv4} from "../contracts/auto-vault-base-v4/AutoStrategyManagerBv4.sol";

contract ManagerHarness is AutoStrategyManagerBv4 {}

/// @dev Covers the two protections on strategy-initiated swaps. The tick gate compares distance from the anchor
///      against an allowance that widens with the anchor's age, and the block guard refuses any anchor written in
///      the current block. Both live in SwapGateLib, which the strategies call for every swap they price.
contract SwapTickGateBv4Test is Test {
    /// @dev sqrt(1) in Q64.96, i.e. currency1 per currency0 of exactly 1.
    uint160 internal constant SQRT_ONE = 79228162514264337593543950336;
    uint256 internal constant DIVISOR = 10_000;
    uint256 internal constant SLIPPAGE_BPS = 100;
    uint256 internal constant MAX_DEV = 2_000;
    /// @dev v4 fees are pips: 1_000_000 = 100%. 10_000 is the 1% tier, 3_000 the 0.3% tier.
    uint24 internal constant NO_FEE = 0;
    uint24 internal constant FEE_ONE_PCT = 10_000;
    uint24 internal constant FEE_THIRTY_BIP = 3_000;

    ManagerHarness internal m;

    function setUp() public {
        m = new ManagerHarness();
        vm.roll(100);
        vm.warp(1_000_000);
    }

    function _anchor(int24 tick, uint64 age, uint64 blocksAgo) internal view returns (SwapGateLib.Anchor memory) {
        return SwapGateLib.Anchor({
            tick: tick,
            has: true,
            time: uint64(block.timestamp) - age,
            blockNumber: uint64(block.number) - blocksAgo
        });
    }

    function _minOut(SwapGateLib.Anchor memory a, int24 poolTick) internal view returns (uint256) {
        return _minOutWithFee(a, poolTick, NO_FEE);
    }

    function _minOutWithFee(SwapGateLib.Anchor memory a, int24 poolTick, uint24 feePips)
        internal
        view
        returns (uint256)
    {
        return SwapGateLib.minOut(SQRT_ONE, poolTick, a, MAX_DEV, true, true, 1e18, SLIPPAGE_BPS, DIVISOR, feePips);
    }

    /// @dev What the pool actually pays out for 1e18 in at parity, after it takes `feePips` off the input.
    function _outputAfterFee(uint24 feePips) internal pure returns (uint256) {
        return (1e18 * (1_000_000 - uint256(feePips))) / 1_000_000;
    }

    // --- deviation allowance ---

    function test_FreshAnchorUsesBaseBound() public pure {
        assertEq(SwapGateLib.allowedTickDeviation(MAX_DEV, 0), 2000);
    }

    function test_AllowanceDoublesPerDayStale() public pure {
        assertEq(SwapGateLib.allowedTickDeviation(MAX_DEV, 1 days), 4000);
        assertEq(SwapGateLib.allowedTickDeviation(MAX_DEV, 2 days), 6000);
        assertEq(SwapGateLib.allowedTickDeviation(MAX_DEV, 7 days), 16000);
    }

    function test_AllowanceGrowsSmoothlyWithinADay() public pure {
        assertEq(SwapGateLib.allowedTickDeviation(MAX_DEV, 12 hours), 3000);
        assertEq(SwapGateLib.allowedTickDeviation(MAX_DEV, 6 hours), 2500);
    }

    /// @dev No matter how far price has run, enough elapsed time reopens swapping, so the strategy cannot be
    ///      permanently stranded waiting for price to return to a stale anchor.
    function testFuzz_SufficientAgeAlwaysClearsAnyDeviation(uint32 deviation) public pure {
        vm.assume(deviation > 0);
        uint256 age = (uint256(deviation) * 1 days) / MAX_DEV + 1 days;
        assertGt(SwapGateLib.allowedTickDeviation(MAX_DEV, age), uint256(deviation));
    }

    function test_ZeroBoundStaysClosed() public pure {
        assertEq(SwapGateLib.allowedTickDeviation(0, 0), 0);
        assertEq(SwapGateLib.allowedTickDeviation(0, 30 days), 0);
    }

    // --- gate applied through minOut ---

    function test_TickWithinAllowanceQuotesFloor() public view {
        assertEq(_minOut(_anchor(0, 1 hours, 1), 100), 0.99e18);
    }

    /// @dev A fresh anchor refuses a move the same anchor permits once it is a day old.
    function test_StaleAnchorClearsMoveThatFreshAnchorBlocks() public view {
        assertEq(_minOut(_anchor(0, 0, 1), 2_500), 0, "fresh anchor should refuse");
        assertGt(_minOut(_anchor(0, 1 days, 1), 2_500), 0, "day-old anchor should permit");
    }

    function test_UninitialisedPoolQuotesNothing() public view {
        SwapGateLib.Anchor memory a = _anchor(0, 1 hours, 1);
        assertEq(SwapGateLib.minOut(0, 0, a, MAX_DEV, true, true, 1e18, SLIPPAGE_BPS, DIVISOR, NO_FEE), 0);
    }

    // --- pool fee ---

    /// @dev The regression. The PoolManager takes the fee off the input before the output is measured against
    ///      this floor, so on a 1% pool a floor that ignores the fee lands exactly on the whole post-fee output
    ///      and leaves nothing for price impact. Deducting the fee is what puts the floor back underneath it.
    function test_FloorLeavesRoomForOnePercentPoolFee() public view {
        SwapGateLib.Anchor memory a = _anchor(0, 1 hours, 1);
        uint256 payable_ = _outputAfterFee(FEE_ONE_PCT);

        assertEq(_minOut(a, 0), payable_, "unfeed floor consumes the entire post-fee output");
        assertLt(_minOutWithFee(a, 0, FEE_ONE_PCT), payable_, "fee-aware floor must sit below it");
    }

    function test_FloorIsQuoteMinusFeeThenSlippage() public view {
        SwapGateLib.Anchor memory a = _anchor(0, 1 hours, 1);
        // 1e18 quote, less the 1% fee, less the 1% tolerance.
        assertEq(_minOutWithFee(a, 0, FEE_ONE_PCT), 0.9801e18);
        // Same, with the 0.3% tier.
        assertEq(_minOutWithFee(a, 0, FEE_THIRTY_BIP), 0.98703e18);
    }

    /// @dev Every tier has to clear, not just the two the vaults use today.
    function testFuzz_FloorAlwaysSitsBelowPostFeeOutput(uint24 feePips) public view {
        feePips = uint24(bound(feePips, 0, 100_000));
        SwapGateLib.Anchor memory a = _anchor(0, 1 hours, 1);
        assertLe(_minOutWithFee(a, 0, feePips), _outputAfterFee(feePips));
    }

    function test_HigherFeeLowersFloor() public view {
        SwapGateLib.Anchor memory a = _anchor(0, 1 hours, 1);
        assertGt(_minOutWithFee(a, 0, FEE_THIRTY_BIP), _minOutWithFee(a, 0, FEE_ONE_PCT));
    }

    /// @dev A fee that swallows the whole input cannot produce a floor, so the caller must skip rather than
    ///      swap against a zero minimum.
    function test_FullFeeQuotesNothing() public view {
        assertEq(_minOutWithFee(_anchor(0, 1 hours, 1), 0, 1_000_000), 0);
    }

    /// @dev The protocol fee comes off the input first and the LP fee off what remains, so the two compound
    ///      rather than add. This is the pairing `AutoStrategyBv4._swapFeePips` hands to the gate.
    function test_ProtocolFeeCompoundsWithLpFee() public view {
        uint24 combined = ProtocolFeeLibrary.calculateSwapFee(1_000, FEE_ONE_PCT);
        assertEq(combined, 10_990, "1000 + 10000 - 1000*10000/1e6");
        assertLt(combined, 1_000 + FEE_ONE_PCT, "compounded, not summed");

        SwapGateLib.Anchor memory a = _anchor(0, 1 hours, 1);
        assertLt(_minOutWithFee(a, 0, combined), _minOutWithFee(a, 0, FEE_ONE_PCT));
        assertLe(_minOutWithFee(a, 0, combined), _outputAfterFee(combined));
    }

    // --- quote math ---

    function test_SpotPriceAtParityIsOne() public pure {
        assertEq(SwapGateLib.spotPrice1e18(SQRT_ONE, true), 1e18);
        assertEq(SwapGateLib.spotPrice1e18(SQRT_ONE, false), 1e18);
    }

    /// @dev Quoting scales linearly in amount, which the old price-then-scale form only approximated.
    function test_QuoteScalesLinearlyWithAmount() public pure {
        assertEq(SwapGateLib.quoteAtSqrt(SQRT_ONE, 1e18, true), 1e18);
        assertEq(SwapGateLib.quoteAtSqrt(SQRT_ONE, 250e18, true), 250e18);
        assertEq(SwapGateLib.quoteAtSqrt(SQRT_ONE, 7, true), 7);
    }

    function test_QuoteInvertsWithCurrencyOrder() public pure {
        // sqrt(4) in Q64.96: currency1 per currency0 of 4.
        uint160 sqrtFour = uint160(SQRT_ONE * 2);
        assertEq(SwapGateLib.quoteAtSqrt(sqrtFour, 1e18, true), 4e18);
        assertEq(SwapGateLib.quoteAtSqrt(sqrtFour, 1e18, false), 0.25e18);
    }

    function test_UninitialisedQuoteIsZero() public pure {
        assertEq(SwapGateLib.quoteAtSqrt(0, 1e18, true), 0);
    }

    // --- swap tolerance is separate from mint tolerance ---

    function test_SwapSlippageDefaultsToOnePercent() public view {
        assertEq(m.swapSlippageBps(), 100);
    }

    function test_SwapSlippageIsCapped() public {
        m.setSwapSlippageBps(1_000);
        assertEq(m.swapSlippageBps(), 1_000);
        vm.expectRevert(AutoStrategyManagerBv4.SwapSlippageBps.selector);
        m.setSwapSlippageBps(1_001);
    }

    /// @dev Widening what a swap will accept must not quietly loosen LP minting, which is why these are two
    ///      settings rather than one.
    function test_SwapSlippageDoesNotMoveMintSlippage() public {
        uint16 mintBefore = m.slippageBps();
        m.setSwapSlippageBps(750);
        assertEq(m.slippageBps(), mintBefore);
    }

    // --- same-block guard ---

    /// @dev An anchor written this block tells us nothing the caller could not have just manufactured: manipulate
    ///      the pool, poke a path that anchors, then swap against the poisoned reference, all in one bundle.
    function test_AnchorWrittenThisBlockRefusesSwap() public view {
        assertEq(_minOut(_anchor(0, 1 hours, 0), 0), 0);
    }

    function test_AnchorFromPreviousBlockIsTrusted() public view {
        assertGt(_minOut(_anchor(0, 1 hours, 1), 0), 0);
    }

    /// @dev The guard is about the anchor's block, not its tick: even a perfectly matching tick is refused.
    function test_SameBlockGuardIgnoresTickAgreement() public view {
        assertEq(_minOut(_anchor(500, 1 hours, 0), 500), 0);
    }

    /// @dev Before the first mint there is no anchor to trust or distrust, so bootstrap swaps are not blocked.
    function test_UnanchoredStrategySkipsBothGates() public view {
        SwapGateLib.Anchor memory none =
            SwapGateLib.Anchor({tick: 0, has: false, time: 0, blockNumber: uint64(block.number)});
        assertEq(_minOut(none, 50_000), 0.99e18);
    }

    // --- owner-settable cadence ---

    /// @dev The reference feed runs on this cadence. Density is a security property, not just freshness:
    ///      movement is capped per unit time, so a shorter interval bounds each individual write more tightly.
    function test_RefUpdateIntervalDefaultsToFiveMinutes() public view {
        assertEq(m.minRefUpdateInterval(), 5 minutes);
    }

    function test_RefUpdateIntervalIsSettable() public {
        m.setMinRefUpdateInterval(15 minutes);
        assertEq(m.minRefUpdateInterval(), 15 minutes);
    }

    function test_MaxSwapTickDeviationIsSettable() public {
        m.setMaxSwapTickDeviation(500);
        assertEq(m.maxSwapTickDeviation(), 500);
        assertEq(SwapGateLib.allowedTickDeviation(m.maxSwapTickDeviation(), 1 days), 1000);
    }

    /// @dev The gate anchors on the reference now, so the widening is driven by the reference's age. At the
    ///      five-minute feed cadence it contributes a fraction of a percent and the bound is effectively fixed —
    ///      where the old remint-driven anchor could reach eight times the base bound after a quiet week.
    function test_FiveMinuteFeedLeavesWideningInert() public view {
        uint256 allowance = SwapGateLib.allowedTickDeviation(m.maxSwapTickDeviation(), 5 minutes);
        assertLe(allowance, (m.maxSwapTickDeviation() * 1005) / 1000);
    }

    /// @dev The widening is retained purely as a deadlock escape for a dead feed: without it, a capped drift plus
    ///      a large move would leave the pool outside a fixed bound and refuse swaps forever.
    function test_WideningStillEscapesDeadlockWhenFeedDies() public view {
        assertEq(SwapGateLib.allowedTickDeviation(m.maxSwapTickDeviation(), 1 days), 2 * m.maxSwapTickDeviation());
    }
}
