// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
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
        return SwapGateLib.minOut(SQRT_ONE, poolTick, a, MAX_DEV, true, true, 1e18, SLIPPAGE_BPS, DIVISOR);
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
        assertEq(SwapGateLib.minOut(0, 0, a, MAX_DEV, true, true, 1e18, SLIPPAGE_BPS, DIVISOR), 0);
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

    /// @dev The keeper refreshes on this cadence, which caps how stale the anchor gets while the position stays in
    ///      range and `keeperCheck` therefore never lands on-chain to remint.
    function test_AnchorRefreshIntervalDefaultsToAnHour() public view {
        assertEq(m.minAnchorRefreshInterval(), 1 hours);
    }

    function test_AnchorRefreshIntervalIsSettable() public {
        m.setMinAnchorRefreshInterval(15 minutes);
        assertEq(m.minAnchorRefreshInterval(), 15 minutes);
    }

    function test_MaxSwapTickDeviationIsSettable() public {
        m.setMaxSwapTickDeviation(500);
        assertEq(m.maxSwapTickDeviation(), 500);
        assertEq(SwapGateLib.allowedTickDeviation(m.maxSwapTickDeviation(), 1 days), 1000);
    }

    /// @dev An hourly refresh keeps the widening well inside the base bound, so the gate stays tight in practice.
    function test_HourlyRefreshKeepsAllowanceNearBase() public view {
        assertLe(SwapGateLib.allowedTickDeviation(m.maxSwapTickDeviation(), 1 hours), (MAX_DEV * 105) / 100);
    }
}
