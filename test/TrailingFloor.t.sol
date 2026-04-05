// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../libraries/LiquidityLibrary.sol";

/// @notice Mirrors FloatStrategy._checkTrailingPriceFloor state machine (NORMAL + position assumed),
/// matching the Node simulation in scripts/trailingFloorSimulation.mjs.
library TrailingFloorLib {
    struct State {
        int24 baselineTick;
        int24 floorTick;
    }

    struct Params {
        uint16 minFloorDeviationBps;
        uint32 floorSlopeNumerator;
        uint32 floorSlopeDenominator;
        int24 tickSpacing;
    }

    function step(State memory s, int24 poolTick, Params memory p) internal pure returns (bool floorHit) {
        if (p.minFloorDeviationBps == 0) {
            s.floorTick = 0;
            return false;
        }
        if (s.baselineTick == 0) {
            s.baselineTick = poolTick;
            s.floorTick = 0;
            return false;
        }
        if (poolTick < s.baselineTick) {
            s.baselineTick = poolTick;
            s.floorTick = 0;
            return false;
        }
        if (s.floorTick != 0 && poolTick < s.floorTick) {
            return true;
        }
        uint256 rallyBps = LiquidityLibrary.priceDeviationBpsAbove(s.baselineTick, poolTick);
        if (rallyBps < p.minFloorDeviationBps) {
            return false;
        }
        uint256 depthBps =
            LiquidityLibrary.trailingFloorDepthBps(rallyBps, p.floorSlopeNumerator, p.floorSlopeDenominator);
        if (depthBps == 0) {
            return false;
        }
        int24 rawFloor = LiquidityLibrary.floorTickBelowCurrentByBps(poolTick, depthBps);
        int24 candidate = LiquidityLibrary.alignDown(rawFloor, p.tickSpacing);
        if (s.floorTick == 0 || candidate > s.floorTick) {
            s.floorTick = candidate;
        }
        return false;
    }
}

contract TrailingFloorTest is Test {
    TrailingFloorLib.Params params = TrailingFloorLib.Params({
        minFloorDeviationBps: 300,
        floorSlopeNumerator: 1,
        floorSlopeDenominator: 3,
        tickSpacing: 200
    });

    function test_ScenarioA_stairStepRally_smallDip_staysAboveFloor() public view {
        TrailingFloorLib.State memory s;
        int24[5] memory ticks = [int24(1000), int24(1500), int24(2000), int24(1800), int24(1900)];
        bool hit;
        for (uint256 i = 0; i < ticks.length; i++) {
            hit = TrailingFloorLib.step(s, ticks[i], params);
            assertFalse(hit);
        }
        assertEq(s.baselineTick, int24(1000));
        assertEq(s.floorTick, int24(1600));
    }

    function test_ScenarioB_rally_then_crossFloor_aboveBaseline() public view {
        TrailingFloorLib.State memory s;
        assertFalse(TrailingFloorLib.step(s, 1000, params));
        assertFalse(TrailingFloorLib.step(s, 4000, params));
        assertEq(s.floorTick, int24(2600));
        bool hit = TrailingFloorLib.step(s, 2500, params);
        assertTrue(hit);
    }

    function test_ScenarioC_largeRally_crossFloor() public view {
        TrailingFloorLib.State memory s;
        assertFalse(TrailingFloorLib.step(s, 1000, params));
        assertFalse(TrailingFloorLib.step(s, 5000, params));
        assertEq(s.floorTick, int24(3200));
        assertTrue(TrailingFloorLib.step(s, 2800, params));
    }

    function test_ScenarioD_dipBelowBaseline_reanchors() public view {
        TrailingFloorLib.State memory s;
        assertFalse(TrailingFloorLib.step(s, 0, params));
        assertFalse(TrailingFloorLib.step(s, 100, params));
        assertFalse(TrailingFloorLib.step(s, -200, params));
        assertEq(s.baselineTick, int24(-200));
        assertEq(s.floorTick, int24(0));
    }
}
