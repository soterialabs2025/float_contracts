# V4 truncated price reference for share minting

Status: plan. Nothing in this document is implemented yet.

## 1. Problem

`AutoVaultBv4` and `AutoVaultRhV4` price share minting off raw `slot0`. The only manipulation-resistant
input they have is `lastSharePriceX18`, an all-time-high WETH-per-share mark that ratchets up and never
comes down. The V4 vault's own comment calls this out — "No TWAP on Bv4 yet" — so the mark was always the
fallback, not the design.

Two consequences, both demonstrated in `test/ShareMintHighWaterBv4.t.sol`:

- **Ordinary drawdown shorts depositors.** `_sharesForDeposit` takes `min(sharesSpot, credited/highWater)`,
  and the high-water branch binds whenever NAV per share sits below its all-time high — the normal state of
  an ASSET/WETH LP after any adverse move. A vault that doubles and gives the gain back credits a 10 WETH
  deposit with 5 shares worth about 5.2 WETH, a 48% entry loss that accrues to incumbent holders.
- **A transient spot spike raises the toll permanently.** NAV is spot-priced with no gate, so one block of
  elevated price plus a dust deposit ratchets the mark to a price that never really existed. In the test a
  3x spike leaves the mark at 3.0; the next 10 WETH deposit gets 3.33 shares worth about 3.57 WETH, a 64%
  haircut that persists for the life of the vault. The attacker recovers under 0.1 ETH, so this is grief
  rather than theft — but it is one transaction and close to free.

The tick anchor does not prevent either. It is consulted only inside `SwapGateLib.minOut`, and when it
refuses, `AutoStrategyBv4._swap` returns silently at line 502 rather than reverting, so the deposit still
completes and still ratchets the mark. Swaps are gated; valuation is not, and minting reads valuation.

A third, separate finding motivates the same mechanism, and it is worse than it first looks.
`minAnchorRefreshInterval = 1 hours` is a *rate limit*, not a schedule — nothing calls `refreshTickAnchor`
automatically. `AutoKeeperBv4.refreshAnchor` / `refreshAnchorBatch` exist as operator entry points but are not
part of `performUpkeep`, so unless the off-chain keeper invokes them deliberately, `lastBandBaseTick` is
written only by a successful `_mintPosition`. Its own doc comment says so: "without it the anchor is only
rewritten by a successful remint and drifts stale in a quiet market."

That matters because the deviation allowance widens with the anchor's age:

```solidity
// SwapGateLib.allowedTickDeviation
return maxDeviation + (maxDeviation * anchorAge) / 1 days;
```

With the anchor advancing only on remints, "age" is time since the last remint — and in a quiet market where
price stays inside the ±600 tick comfort band, no remint happens:

| Time since last remint | Allowance | Price move tolerated |
| --- | --- | --- |
| Fresh | 2,000 ticks | 22% |
| 1 day | 4,000 ticks | 49% |
| 3 days | 8,000 ticks | 123% |
| 7 days | 16,000 ticks | 396% |

So the swap gate is loosest exactly when the market has been calm, which is backwards. And when the anchor
*is* refreshed, it stores raw spot, so a single well-timed refresh adopts a manipulated tick wholesale.

## 2. What already exists — V3 defines the slot

All three V3 stacks already take a fourth argument and prefer an oracle-derived NAV, using the high-water
only when the oracle cannot answer:

```solidity
// AutoVaultBv3._sharesForDeposit
if (navTwap > 0) {
    return Math.min(sharesSpot, Math.mulDiv(credited, supply, navTwap));
}
if (lastSharePriceX18 == 0) return sharesSpot;
return Math.min(sharesSpot, Math.mulDiv(credited, 1e18, lastSharePriceX18));
```

| Stack | Signature | Reference for minting |
| --- | --- | --- |
| Bv3, RhV3, Sv3 | 4-arg with `navTwap` | TWAP, high-water as fallback |
| Bv4, RhV4 | 3-arg | High-water, always |

So this is not a new architecture. V4 needs to supply the missing input and adopt V3's four-argument form,
which also puts all five stacks on one interface.

## 3. Why not the Uniswap truncated oracle hook

The [truncated oracle hook](https://blog.uniswap.org/uniswap-v4-truncated-oracle-hook) is the right *idea*
and the wrong *packaging* for us.

Hooks are part of the `PoolKey`, so one cannot be attached to a pool that already exists — adopting it means
deploying our own pool and bootstrapping liquidity into it. And
[`TruncGeoOracle`](https://raw.githubusercontent.com/Uniswap/v4-periphery/refs/heads/trunc-oracle/contracts/hooks/TruncGeoOracle.sol)
requires `key.fee == 0`, maximum tick spacing, full-range-only positions, and permanently locked liquidity
(`beforeModifyPosition` reverts on any negative `liquidityDelta`). It is a dedicated oracle pool, deliberately
not a tradeable one, and is structurally incompatible with an active LP strategy.

Truncation itself needs no hook. It only requires that our stored reference refuses to move more than a
bounded amount per unit time.

A withdrawal delay was considered and rejected. Partial exits size in liquidity units, not price
(`liqToRemove = liquidity * userShares / totalSupply_`), and the payout swap degrades gracefully by sending
unsold amounts out in the original token. Withdrawals are the well-protected path already.

A ring buffer of observations — a true on-chain TWAP — was considered and rejected on size. Truncation needs
one slot and no loop, and per the Uniswap post is at least as manipulation-resistant as a short-window mean.

## 4. Design

### 4.1 A separate field, because the existing anchor cannot be refreshed faster

`lastBandBaseTick` already does double duty: it anchors the swap gate, and `_inInnerComfort()` builds the
inner comfort band from it. Since `refreshTickAnchor` re-centres it on current spot, raising that function's
cadence to five minutes would make the ±600 tick comfort band chase price continuously, `_inInnerComfort()`
would be true almost always, and the inner remint trigger would stop firing — rebalancing degrading to outer
range exits only.

So the dense feed writes its own field, and `lastBandBaseTick` is left to serve the comfort band alone,
written only by `_mintPosition`. §4.9 removes the refresh path that could disturb it.

```
int24  refTick    // truncated price reference
uint64 refTime    // when it was last written
```

Both pack into one slot.

### 4.2 A dense off-chain feed, and why density is a security gain

The keeper writes `refTick` every 5 minutes (15 acceptable, tolerated to hours). At Base gas this is under a
cent per write.

Density is not just about freshness. Movement is bounded per unit time, so a shorter interval bounds each
individual write more tightly, which directly limits how far one poisoned write can push the reference:

| Keeper interval | Max movement per write | As a price move |
| --- | --- | --- |
| 5 minutes | 150 ticks | 1.5% |
| 15 minutes | 450 ticks | 4.6% |
| 1 hour | 1,800 ticks | 19.7% |

The sparse, remint-driven cadence of the current anchor is what makes one well-timed write so damaging. At
five minutes the same poisoning is worth 1.5%.

### 4.3 Drift is rate-limited in time, not per block

The blog's hook caps movement per *block* because it updates on every swap. Ours updates on keeper cadence, so
a per-block cap is meaningless. Rate-limit per second instead, which makes the bound independent of update
frequency and robust to a missed write:

```
elapsed = block.timestamp - refTime
drift   = min(elapsed / secondsPerRefTick, maxRefDrift)
```

Default `secondsPerRefTick = 2`, i.e. half a tick per second. One Base block buys an attacker 1 tick (0.01%);
sustaining a manipulation for 30 minutes buys 900 ticks (9.4%), by which point arbitrage has had thirty
minutes to eat it. That is the economic argument from the Uniswap post, unchanged.

### 4.4 Clamp on read, not on write

The cheapest correct form: no storage write on the deposit path at all. Store `refTick` on keeper cadence, and
clamp at consumption time.

```
effTick = clamp(spotTick, refTick - drift, refTick + drift)
```

Manipulation beyond the drift band does not move the price used for minting, and deposits take no extra
`SSTORE`.

### 4.5 Degradation is graceful, and there is no halt

Deposits must never stop, so there is no staleness cutoff and no fallback branch. The clamp degrades on its
own: as `drift` grows, `clamp(spot, refTick ± drift)` converges on `spot`, so `sharesAtRef` converges on
`sharesSpot` and the `min` becomes a no-op. A neglected reference relaxes toward today's behaviour instead of
blocking anything.

`maxRefDrift` (default 2,000 ticks, matching `maxSwapTickDeviation`) stops that relaxation short of nothing, so
protection never fully disappears. At the default rate the cap binds only after ~67 minutes of keeper silence,
so it is invisible in normal operation and only shapes the outage case.

The cost of the cap is that a keeper outage *combined with* a genuine move beyond 22% under-credits depositors
until the keeper returns. That is the conservative direction, it never halts, and it needs both failures at
once.

### 4.6 The same clamp fixes the anchor poisoning

The gate's anchor becomes `refTick`, which is clamped on every write, so a manipulated tick can move it by at
most `drift` — 150 ticks at the five-minute cadence. One mechanism, both problems. §4.9 covers the rest.

### 4.9 The swap gate anchors on the reference too — in scope

`SwapGateLib.minOut` moves off `lastBandBaseTick` and onto `refTick`. The gate then measures against a value
refreshed every five minutes rather than one that can be a week old.

**The age-widening stays, but changes what it measures.** Deleting it outright would reintroduce the deadlock
it was built for: with drift capped at `maxRefDrift`, a dead keeper plus a large move leaves the pool
permanently outside a fixed bound, swaps refused forever. Driving the same formula off `refTime` instead of
the mint anchor's age solves both problems at once:

| Reference age | Widening factor | Meaning |
| --- | --- | --- |
| 5 minutes (feed healthy) | 1.003x | Inert. The gate is effectively fixed. |
| 1 day | 2x | Feed has been down a day; gate loosens. |
| 7 days | 8x | Deadlock escape. |

In normal operation the widening contributes 0.3% and the 396%-after-a-week allowance in §1 disappears. It
only opens up during a keeper outage, which is exactly when a deadlock escape is wanted.

**`maxSwapTickDeviation` tightens below the outer band width.** I previously treated ~800 ticks as a hard
floor because reminting fires on band exit and the anchor was the mint tick. Against a reference tracking at
half a tick per second that floor dissolves: a genuine 10% move over ten minutes leaves a gap of about 650
ticks, so a bound around 1,000 refuses only genuinely *fast* moves, which is the intent. Default drops from
2,000 to 1,000 on Bv4 and 2,400 to 1,200 on RhV4. This is what finally addresses the concession in
`AutoStrategyManagerBv4`: "Catches gross manipulation only, not ordinary sandwich-scale movement."

**`refreshTickAnchor` is deleted, along with its keeper plumbing.** Once the gate no longer reads
`lastBandBaseTick`, that field serves only `_inInnerComfort`, and re-centring it on spot does nothing but
suppress reminting — the function becomes purely harmful. Removing it also frees `lastBandBaseTime`,
`lastBandBaseBlock`, `minAnchorRefreshInterval`, and `AutoKeeperBv4.refreshAnchor` / `refreshAnchorBatch`.
`lastBandBaseTick` and `hasBandBase` stay, written only by `_mintPosition`, serving only the comfort band.

Net effect on §6's budget is a *refund* rather than a cost, since the removals roughly offset the new
reference fields and `poolValueRef`.

**Residual risk:** rebalance liveness now depends on the keeper feed. A dead feed plus a fast move refuses
rebalancing swaps until the widening catches up — hours, not permanent. Previously that failure mode did not
exist because the gate was loose enough to never refuse much. This is a deliberate trade: a gate that can
occasionally be too strict, in exchange for one that is not 396% wide after a quiet week.

### 4.7 The `min` is safe at any divergence — which is the key simplification

`min(sharesSpot, sharesAtRef)` selects whichever NAV is *higher*, so:

- An attacker depressing spot NAV to overmint gets `sharesSpot` high, but the reference NAV is unmanipulated
  and higher, so the `min` picks the reference. Blocked.
- An attacker inflating spot NAV makes `sharesSpot` low, and the `min` picks it. Fewer shares, no gain.

The reference therefore does not need to be accurate. It only needs to resist being pushed *down*. Two
consequences: the clamp can be loose without being unsafe, and **no deviation gate belongs in the minting
path** — see §5.

It also bounds the residual cost. Because `min` takes the higher NAV, a reference lagging *below* spot is
ignored entirely, so a rising market never under-credits. Only a fast *drawdown* under-credits, and only until
the reference tracks down — bounded by §4.3 at roughly half an hour for a 9% fall, against the high-water
mark's forever.

### 4.8 Delete the high-water mark

Confirmed no indexer depends on `lastSharePriceX18()` or `SharePriceHighWater`, so both go, along with
`_bumpSharePriceHighWater` and the reset in `withdraw`. With §4.5 there is no state in which a fallback is
needed, so `_sharesForDeposit` loses a branch as well as gaining an argument:

```solidity
function _sharesForDeposit(uint256 credited, uint256 navBefore, uint256 supply, uint256 navRef)
    internal
    pure
    returns (uint256)
{
    if (supply == 0) return credited;
    uint256 sharesSpot = navBefore == 0 ? type(uint256).max : Math.mulDiv(credited, supply, navBefore);
    if (navRef == 0) return sharesSpot; // reference not yet seeded, i.e. before the first mint
    return Math.min(sharesSpot, Math.mulDiv(credited, supply, navRef));
}
```

Simpler than V3's, and `pure`. The removals also refund bytecode, which §6 shows we need.

## 5. V3 is exposed too, and the fix is smaller

`poolValueTwap()` returns `_navAtPrice(_rebalancePrice1e18())`, and `_rebalancePrice1e18` yields zero whenever
spot sits more than `maxTwapDeviationBps` (300 bps default) from TWAP. Inside that window V3 deposits fall
through to the same all-time-high branch and take the same full-drawdown penalty. Not rare for a volatile
token, just transient.

By §4.7 the deviation gate is unnecessary here. It exists to protect the *rebalance* path, where the strategy
is about to trade. Minting does not trade; it prices, and taking the `min` of two prices is safe however far
apart they are. Rejecting the TWAP for deviation is what drops V3 into the ratcheting fallback, so the gate is
not merely redundant, it is the cause.

Fix: expose an ungated TWAP NAV for the minting path and leave `poolValueTwap()` alone for rebalancing. The
high-water fallback then triggers only on a genuinely unreadable oracle, and can stay.

As built: `poolValueTwapRaw()` on all three V3 strategies, returning `_navAtPrice(_twapPrice1e18())` against
`poolValueTwap()`'s `_navAtPrice(_rebalancePrice1e18())`. Two existing internals, so the added cost is the
external entry point only. The three vaults call it in place of `poolValueTwap()` at the same pre-deposit
sample point; `_sharesForDeposit` is untouched, since it already takes `navTwap` and already falls back to the
high-water on zero. `poolValueTwap()` keeps its gate and its meaning for every other caller — nothing outside
the minting path consumed it.

## 6. Size budget — this is the binding constraint

Measured on the current tree:

| Contract | Size | Free |
| --- | --- | --- |
| `AutoFactoryBv4` | 48,111 initcode | **1,041** |
| `AutoFactoryRhV4` | 45,728 initcode | 3,424 |
| `AutoStrategyBv4` | 21,780 runtime | 2,796 |
| `AutoStrategyRhV4` | 20,589 runtime | 3,987 |
| `AutoVaultBv4` | 6,244 runtime | 18,332 |
| `SwapGateLib` (Bv4) | 1,948 runtime | 22,628 |

The Bv4 factory's runtime is only 5,765 against 48,111 of initcode, so its constructor deploys the
implementations: **every byte added to the strategy or the vault costs the factory roughly one byte**, against
1,041 bytes of headroom. The vault's own 18 KB of slack is irrelevant.

Consequences for the plan:

- Clamp arithmetic and quote math go in `SwapGateLib`, which is externally linked. Growth there is free to the
  factory.
- The strategy gains `poolValueRef()`, `refreshPriceRef()` and one packed slot — arithmetic delegated.
- Against that, §4.9 deletes `refreshTickAnchor`, two anchor fields and `minAnchorRefreshInterval` from the
  strategy, and the high-water mark plus a branch from the vault. The release is expected to come out roughly
  neutral or better on the factory, not worse.
- RhV4 has 3,424 free and is comfortable. **Bv4 is the one to watch**; if it does not fit, the fallback is to
  move `_navAtPrice` into `LiquidityLibraryV4` as another linked `public` function.
- Re-measure after each of the three phases in §11, not just at the end.

### 6.1 As-built (measured after implementation)

| Contract | Size | Free | vs. plan |
| --- | --- | --- | --- |
| `AutoFactoryBv4` | 48,726 initcode | **426** | −615 |
| `AutoFactoryRhV4` | 46,260 initcode | 2,892 | −532 |
| `AutoStrategyBv4` | 22,631 runtime | 1,945 | −851 |
| `AutoStrategyRhV4` | 21,375 runtime | 3,201 | −786 |
| `SwapGateLib` (both) | 4,158 runtime | 20,418 | +2,210 |

The forecast in §6 was wrong in direction: the deletions did not offset the additions, and Bv4 landed 615
bytes worse rather than neutral. The library grew by 2,210 bytes, which is free, but each new library entry
point costs the *strategy* a `DELEGATECALL` plus its ABI encoding, and three of those exceeded the factory's
1,041-byte budget on their own. The fix was to collapse `refDrift` + `clampTick` + `priceAtTick` into two
composite entry points, `nextRefTick` and `refPrice1e18`, so the strategy pays for one call instead of three:
351 bytes recovered. That is what makes the 426-byte margin, and it is thin enough that the next change to
either the strategy or the vault should budget for moving `_navAtPrice` into `LiquidityLibraryV4`.

Both `SwapGateLib` copies compile to exactly 4,158 bytes, which is the check that the RhV4 mirror is
character-exact rather than merely equivalent.

## 7. Changes by file

**`libraries/SwapGateLib.sol`** (Bv4 + RhV4, external, free)
- `refDrift(uint64 refTime, uint256 secondsPerRefTick, uint256 maxRefDrift)` — allowed movement.
- `clampTick(int24 spotTick, int24 refTick, uint256 drift)` — the truncation, shared by the reference write
  and by the gate.
- `priceAtTick(int24 tick, bool wethIsCurrency0)` — reuse `quoteAtSqrt` via `TickMath`.
- `Anchor` struct repurposed to carry `refTick` / `refTime` / `refBlock`; `allowedTickDeviation` now takes the
  reference's age (§4.9).

**`AutoStrategyManagerBv4.sol`** (+ RhV4 twin)
- `uint256 public secondsPerRefTick = 2;` capped setter (reject 0).
- `uint256 public maxRefDrift = 2000;` capped setter.
- `uint256 public minRefUpdateInterval = 5 minutes;` setter.
- `maxSwapTickDeviation` default 2,000 → 1,000 (RhV4: 2,400 → 1,200).
- Remove `minAnchorRefreshInterval`.

**`AutoStrategyBv4.sol`** (+ RhV4 twin)
- `int24 refTick` / `uint64 refTime` / `uint64 refBlock`, one slot, seeded on first `_mintPosition`.
- `refreshPriceRef() external` — keeper-gated, rate-limited by `minRefUpdateInterval`, writes the clamped tick.
- `poolValueRef() external view returns (uint256)` — NAV with pool amounts at spot, valued at the clamped tick,
  mirroring V3's `_navAtPrice`. Returns 0 only when unseeded or the pool is uninitialised.
- `_minOutForSwap` builds its `Anchor` from the reference fields.
- Remove `refreshTickAnchor`, `lastBandBaseTime`, `lastBandBaseBlock`. `_setBandBase` keeps only
  `lastBandBaseTick` and `hasBandBase`.
- Interface: add `refreshPriceRef` and `poolValueRef`, drop `refreshTickAnchor`.

**`AutoVaultBv4.sol`** (+ RhV4 twin)
- Sample `strategy.poolValueRef()` *before* `strategy.deposit`, matching V3's "TWAP must be sampled
  pre-deposit" note.
- `_sharesForDeposit` per §4.8.
- Remove `lastSharePriceX18`, `_bumpSharePriceHighWater`, `SharePriceHighWater`, and the reset in `withdraw`.

**`AutoKeeperBv4.sol`** (+ RhV4 twin)
- Rename `refreshAnchor` / `refreshAnchorBatch` to `refreshPriceRef` / `refreshPriceRefBatch` and repoint them
  at the new strategy function. The batch form amortises the base transaction cost across every watched
  strategy, which matters at a 5-minute cadence.

**Keeper (off-chain)**
- Call `refreshPriceRefBatch` on a 5-minute schedule, independent of `performUpkeep`'s out-of-range simulation.
- Alert if the last successful write is older than 30 minutes; §4.5 means this degrades rather than breaks, so
  it is a monitoring signal, not an incident.

**V3 stacks** (Bv3, RhV3, Sv3)
- Ungated TWAP NAV for the minting path; leave `poolValueTwap()` for rebalancing.

## 8. Test plan

- Rewrite `test/ShareMintHighWaterBv4.t.sol` to assert the *desired* behaviour: the drawdown case credits at
  spot, and the transient-spike case is unaffected by the spike.
- Clamp unit tests in the `SwapGateLib` suite: drift at 0s / 5min / 1h, `maxRefDrift` cap binding at ~67
  minutes, clamp above and below.
- Anchor poisoning: a manipulated tick at refresh time moves `refTick` by at most `drift`.
- Liveness: deposits succeed with a reference one week stale, and the clamp has by then converged to spot.
- Rising market never under-credits (the `min` picks spot); fast drawdown under-credits and recovers within the
  window §4.7 predicts.
- Rebalancing: `_inInnerComfort` fires on comfort-band exit exactly as before, unaffected by the 5-minute
  reference — the existing `SwapTickGateBv4` suite should confirm the two are independent.
- Swap gate (§4.9): widening is inert at a 5-minute reference age and reaches 2x at one day; the tightened
  `maxSwapTickDeviation` still passes a legitimate 10%-over-10-minutes move; a dead feed plus a large move
  refuses swaps and then recovers as the widening grows.
- V3: deposits during a >3% spot/TWAP deviation no longer touch the high-water branch.
- Mirror everything to RhV4.

## 9. Consequences and accepted risks

- **No halt, ever.** Deposits never revert on reference state; §4.5 degrades instead.
- **A fast drawdown under-credits depositors for up to ~30 minutes.** Conservative direction, self-correcting,
  and bounded — against the high-water mark, which was unbounded and permanent. Rising markets are unaffected
  because the `min` ignores a low reference.
- **Keeper outage plus a >22% move under-credits until the keeper returns.** Requires both failures at once;
  the alternative was uncapped drift and no protection at all.
- **Griefing the reference upward is possible but decays.** Movement is capped per write and reverts as the
  reference tracks real price, unlike the high-water mark where the same grief was permanent.
- **Rebalance liveness now depends on the keeper feed.** §4.9's tightened gate can refuse a rebalancing swap
  during a fast move if the feed is down. Recovers as the widening grows; hours, not permanent. This failure
  mode did not exist before because the gate was too loose to refuse much.
- **New recurring cost.** One batched transaction per 5 minutes covering all watched strategies, ~288/day.
- **Breaking change.** New strategy and new vault must ship together; the vault calls `poolValueRef()`, which
  older strategies do not implement.
- **Storage layout changes** on both the vault and the strategy. These are cloned implementations, so only new
  packages are affected — existing deployed packages cannot be upgraded into this.

## 10. Port matrix

| Stack | Reference | Vault minting | High-water |
| --- | --- | --- | --- |
| Bv4 | new truncated `refTick`, 5-minute feed | 4-arg | removed |
| RhV4 | new truncated `refTick`, 5-minute feed | 4-arg | removed |
| Bv3 | existing TWAP, `poolValueTwapRaw()` for minting | already 4-arg | retained as true fallback |
| RhV3 | same as Bv3 | already 4-arg | retained |
| Sv3 | same as Bv3 | already 4-arg | retained |

`ustrategy-rh-v4` shares `LiquidityLibraryV4` but not the vault, and is out of scope until the V4 stacks land.

## 11. Build order

Three phases, each independently testable, sizes re-measured after each.

1. **Reference infrastructure.** `SwapGateLib` helpers, manager settings, strategy fields, `refreshPriceRef`,
   `poolValueRef`, keeper rename. No consumer changes yet, so the existing suite must stay green.
2. **Minting.** Vault takes `poolValueRef()`, `_sharesForDeposit` gains the argument, high-water removed.
   Rewrite `ShareMintHighWaterBv4.t.sol` against the intended behaviour.
3. **Swap gate (§4.9).** Repoint `Anchor`, drive the widening off reference age, tighten
   `maxSwapTickDeviation`, delete `refreshTickAnchor` and its plumbing.

Then mirror all three to RhV4, and do the separate, much smaller V3 change in §5.

### 11.1 What actually shipped

Phases 1 and 3 were **merged and landed together**, not sequenced. Phase 1 alone pushed `AutoFactoryBv4` over
EIP-3860: it adds the reference fields and entry points while leaving the old anchor plumbing in place, so the
strategy briefly carries both. Since phase 3's deletions (`refreshTickAnchor`, `lastBandBaseTime`,
`lastBandBaseBlock`, `minAnchorRefreshInterval`) are what pay for phase 1's additions, there is no ordering
of the two that fits. Phase 2 then landed separately as planned.

Sequence as built:

1. Phases 1 + 3 together on Bv4 — library helpers, manager settings, reference fields, `refreshPriceRef`,
   `poolValueRef`, gate repointed to `refTick`, old anchor plumbing deleted. 152 tests green.
2. Phase 2 on Bv4 — vault minting on `poolValueRef()`, high-water removed, `ShareMintHighWaterBv4` rewritten.
3. RhV4 mirror, adapted rather than copied: RhV4 pairs against native ETH, so `poolValueRef` and the gate test
   `_poolKey.currency0 == address(0)` instead of `== address(WETH)`, and `_minOutForSwap` keeps its
   `bool sellEth` signature.
4. V3 change per §5.

The lesson for the next release is that the "each phase independently testable" structure assumed additions
and deletions were separable. Under a hard size ceiling they are not, and phasing has to follow the byte
budget rather than the logical decomposition.
