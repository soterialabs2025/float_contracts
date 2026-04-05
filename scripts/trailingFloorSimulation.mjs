/**
 * Simulation of FloatStrategy._checkTrailingPriceFloor (lines ~239–288) using the same
 * math as LiquidityLibrary + TickMath (via @uniswap/v3-sdk).
 *
 * Run from repo root: node .claude/worktrees/zen-hellman/scripts/trailingFloorSimulation.mjs
 */

import { createRequire } from "module";
import JSBI from "jsbi";

const require = createRequire(import.meta.url);
const { TickMath } = require("@uniswap/v3-sdk");

const toBI = (j) => BigInt(j.toString());

/** Solidity-compatible uint256 sqrt (LiquidityLibrary.sqrt) */
function sqrtU256(y) {
  if (y === 0n) return 0n;
  let x = y;
  let z = (x + 1n) / 2n;
  while (z < x) {
    x = z;
    z = (y / z + z) / 2n;
  }
  return x;
}

/** LiquidityLibrary.sqrt1e18 */
function sqrt1e18(x1e18) {
  const maxSafe = (2n ** 256n - 1n) / 10n ** 18n;
  if (x1e18 > maxSafe) {
    const sx = sqrtU256(x1e18);
    return sx * 10n ** 18n;
  }
  return sqrtU256(x1e18 * 10n ** 18n);
}

/** priceDeviationBpsAbove */
function priceDeviationBpsAbove(anchorTick, currentTick) {
  if (currentTick <= anchorTick) return 0n;
  const sa = toBI(TickMath.getSqrtRatioAtTick(anchorTick));
  const sc = toBI(TickMath.getSqrtRatioAtTick(currentTick));
  const sa2 = sa * sa;
  const sc2 = sc * sc;
  const priceRatio1e18 = (sc2 * 10n ** 18n) / sa2;
  if (priceRatio1e18 <= 10n ** 18n) return 0n;
  return ((priceRatio1e18 - 10n ** 18n) * 10000n) / 10n ** 18n;
}

function trailingFloorDepthBps(rallyBps, num, den) {
  if (den === 0n) return 0n;
  return (rallyBps * num) / den;
}

/** floorTickBelowCurrentByBps — matches LiquidityLibrary */
function floorTickBelowCurrentByBps(currentTick, depthBps) {
  if (depthBps === 0n) return currentTick;
  let d = depthBps;
  if (d >= 10000n) d = 9999n;
  const sc = toBI(TickMath.getSqrtRatioAtTick(currentTick));
  const priceFactor1e18 = ((10000n - d) * 10n ** 18n) / 10000n;
  const sqrtScale1e18 = sqrt1e18(priceFactor1e18);
  const newSqrt256 = (sc * sqrtScale1e18) / 10n ** 18n;
  const MIN_SQRT = 4295128739n;
  const MAX_SQRT = 1461446703485210103287273052203988822378723970342n;
  let ns = newSqrt256;
  if (ns <= MIN_SQRT) return TickMath.MIN_TICK;
  if (ns >= MAX_SQRT) ns = MAX_SQRT - 1n;
  const tick = Number(
    TickMath.getTickAtSqrtRatio(JSBI.BigInt(ns.toString())),
  );
  return tick;
}

/** alignDown — matches LiquidityLibrary */
function alignDown(tick, spacing) {
  const r = tick % spacing;
  if (r === 0) return tick;
  return tick < 0 ? tick - r - spacing : tick - r;
}

/**
 * One keeper step: same control flow as _checkTrailingPriceFloor when mode=NORMAL and positionId>0.
 * Returns updated state + whether keeper would need another pass for liquidity (remainingLiq) — omitted; we only model bool floorHit.
 */
function checkTrailingPriceFloor(state, poolTick, params) {
  let { baselineTick, floorTick } = state;
  const {
    minFloorDeviationBps,
    floorSlopeNumerator,
    floorSlopeDenominator,
    tickSpacing,
  } = params;

  if (minFloorDeviationBps === 0) {
    return { baselineTick, floorTick, floorHit: false, note: "floor disabled" };
  }

  if (baselineTick === 0) {
    baselineTick = poolTick;
    floorTick = 0;
    return {
      baselineTick,
      floorTick,
      floorHit: false,
      note: "init baseline",
    };
  }

  if (poolTick < baselineTick) {
    baselineTick = poolTick;
    floorTick = 0;
    return {
      baselineTick,
      floorTick,
      floorHit: false,
      note: "re-anchor below baseline",
    };
  }

  if (floorTick !== 0 && poolTick < floorTick) {
    return {
      baselineTick,
      floorTick,
      floorHit: true,
      note: "crossed floor → defensive path",
    };
  }

  const rallyBps = priceDeviationBpsAbove(baselineTick, poolTick);
  if (rallyBps < BigInt(minFloorDeviationBps)) {
    return {
      baselineTick,
      floorTick,
      floorHit: false,
      rallyBps,
      note: "rally below min — no floor update (attached code)",
    };
  }

  const depthBps = trailingFloorDepthBps(
    rallyBps,
    BigInt(floorSlopeNumerator),
    BigInt(floorSlopeDenominator),
  );
  if (depthBps === 0n) {
    return { baselineTick, floorTick, floorHit: false, rallyBps, note: "depth 0" };
  }

  const rawFloor = floorTickBelowCurrentByBps(poolTick, depthBps);
  const candidate = alignDown(rawFloor, tickSpacing);

  // High-water mark (lines 283–286 in user file)
  if (floorTick === 0 || candidate > floorTick) {
    floorTick = candidate;
  }

  return {
    baselineTick,
    floorTick,
    floorHit: false,
    rallyBps,
    depthBps,
    candidate,
    note: "floor ratchet",
  };
}

function logStep(label, s) {
  console.log(`  ${label}: baseline=${s.baselineTick} floor=${s.floorTick} hit=${s.floorHit} | ${s.note}`);
  if (s.rallyBps !== undefined)
    console.log(`    rallyBps=${s.rallyBps} depthBps=${s.depthBps ?? "n/a"}`);
}

const defaultParams = {
  minFloorDeviationBps: 300,
  floorSlopeNumerator: 1,
  floorSlopeDenominator: 3,
  tickSpacing: 200,
};

console.log("=== Trailing floor simulation (matches attached FloatStrategy 239–288) ===\n");

// Scenario A: mint-equivalent start tick, rally, then dip but stay above ratcheted floor
console.log("Scenario A: stair-step rally, then small dip (still above floor)");
{
  let st = { baselineTick: 0, floorTick: 0 };
  const ticks = [1000, 1500, 2000, 1800, 1900];
  for (const t of ticks) {
    const r = checkTrailingPriceFloor(st, t, defaultParams);
    st = { baselineTick: r.baselineTick, floorTick: r.floorTick };
    logStep(`poolTick=${t}`, r);
  }
}

// Scenario B: rally arms floor; dip through floor (still above baseline) → hit
console.log("\nScenario B: rally arms floor, then dip below floor but above baseline → hit");
{
  let st = { baselineTick: 0, floorTick: 0 };
  const ticks = [1000, 4000, 2500];
  for (const t of ticks) {
    const r = checkTrailingPriceFloor(st, t, defaultParams);
    st = { baselineTick: r.baselineTick, floorTick: r.floorTick };
    logStep(`poolTick=${t}`, r);
    if (r.floorHit) break;
  }
}

// Scenario C: rally arms a floor; spot stays above baseline but drops below floor → defensive
console.log(
  "\nScenario C: rally → floor armed; pullback stays above baseline but crosses floor → hit",
);
{
  let st = { baselineTick: 0, floorTick: 0 };
  const ticks = [1000, 5000, 2800];
  for (const t of ticks) {
    const r = checkTrailingPriceFloor(st, t, defaultParams);
    st = { baselineTick: r.baselineTick, floorTick: r.floorTick };
    logStep(`poolTick=${t}`, r);
    if (r.floorHit)
      console.log(
        "    (poolTick still > baselineTick but poolTick < floorTick → trailing stop.)",
      );
  }
}

// Scenario D: price below baseline resets trail (no defensive if floor not armed)
console.log("\nScenario D: dip below baseline before floor armed → re-anchor");
{
  let st = { baselineTick: 0, floorTick: 0 };
  const ticks = [0, 100, -200];
  for (const t of ticks) {
    const r = checkTrailingPriceFloor(st, t, defaultParams);
    st = { baselineTick: r.baselineTick, floorTick: r.floorTick };
    logStep(`poolTick=${t}`, r);
  }
}

console.log("\nDone.");
