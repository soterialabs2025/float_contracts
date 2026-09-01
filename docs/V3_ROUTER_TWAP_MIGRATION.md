# V3 swap hardening: caller-supplied `minOut` from TWAP

Plan for closing the V3 swap-gate findings **in place** — inside `AutoStrategyBv3` and
`ShareStakingBv3`, mirroring the `AutoSwapRouterBv4` hardening already shipped.

Relocating the TWAP oracle into the shared router was considered and **rejected** as too large a
change. See §8 for what was rejected and why, so the option is not re-litigated from scratch.

**Status:** Plan — not yet implemented.

---

## 1. Findings and fix order

| ID | Severity | Finding | Fix |
|----|----------|---------|-----|
| **R3-QUOTE** | High | `minOut` derived from an in-transaction `QuoterV2` simulation, so the floor moves with the manipulation | §4 — caller-supplied `minAmountOut`; quoter deleted |
| **R3-WITHDRAW** | High | `_payWithdraw` (lines 290, 298) swaps with no TWAP gate; sandwichable and attacker-schedulable | §5 — `_swap` derives a TWAP floor |
| **R3-STAKING** | High | `ShareStakingBv3` swaps with no TWAP gate; losses socialize across epoch stakers | §6 — `strategy.minOutForSwap` |
| **R3-CONFIG** | Medium | `setStrictStrategySlippageBps` accepts `10_000` (⇒ `minOut == 0`); `setMaxTwapDeviationBps` accepts `DIVISOR` | §7 — hard caps |
| **R3-REVOKE** | Low | No `removeAuthorizedStrategy`, no `rescue` | §4 |

**Sequencing note.** The review suggested fixing 1 and 2 before 3. Implementing it that way means
writing gate-only code and then rewriting it once the signature changes, and gate-only fixes are
partial anyway — they block swaps outside the deviation band but leave a real sandwich window
*inside* it, because the floor is still the manipulated quote. Landing **R3-QUOTE first** makes the
other two fall out as ordinary callers of the new signature. Same destination, no rework.

---

## 2. The key structural point

`AutoStrategyBv3._swap` (line 399) is the strategy's **internal chokepoint**. Both ungated call
sites reach the router through it:

- `_balanceTokens` lines 395–396 (currently gated by the caller)
- `_payWithdraw` lines 290, 298 (currently ungated — **R3-WITHDRAW**)

So deriving the floor *inside* `_swap` covers both paths with one change, and gets the same
fail-closed property the router migration was going to buy — without moving any architecture.
`ShareStakingBv3` is the only caller outside the strategy, and §6 handles it.

---

## 3. Size constraint — read before starting

Measured under profile `base-v3`:

| Contract | Runtime | Initcode | Margin |
|----------|---------|----------|--------|
| `AutoStrategyBv3` | 23,574 | 24,288 | **1,002 to EIP-170** |
| `AutoFactoryBv3` | 5,451 | 48,150 | **1,002 to EIP-3860** |
| `AutoSwapRouterBv3` | 2,738 | 2,981 | 21,838 spare |

This plan **adds** code to `AutoStrategyBv3` (floor derivation plus a public view) against a
1,002-byte margin. Deleting the quoter shrinks the *router*, which is not where the pressure is, so
it provides no relief. `TickMath` also stays inlined via `TrailingFloorLib` and
`LiquidityLibraryV2`, so no structural saving is available there either.

Nor is there compiler-level slack: `base-v3` already runs `optimizer_runs = 1`, `via_ir = true`,
`bytecode_hash = "none"`, and `cbor_metadata = false`. The 1,002 bytes is what remains *after* every
cheap trick.

Expected addition is roughly 400–800 bytes — a shared internal floor helper, a thin
`minOutForSwap` view over it, and one `swapSlippageBps` slot with a capped setter. Measure after §5.

**Escape hatches, in order. Linked libraries are the last resort, not the first.**

1. Shave inside `AutoStrategyBv3`; keep exactly one internal floor helper shared by `_swap` and
   `minOutForSwap`.
2. Relocate anything that does not have to live in the strategy. The pressure is confined to one
   contract — `ShareStakingBv3` has 17,191 bytes spare, `AutoVaultBv3` 18,802, `AutoFactoryBv3`
   19,125 runtime.
3. Only then extract to a linked library (`SwapGateLib` pattern from `auto-vault-base-v4`).

Note that (3) carries a cost specific to this stack: **V3 currently has no linked libraries at
all.** Every function under `auto-vaults-base-v3/libraries` is `internal` and inlines, so the
strategy deploys with no linking step today. Introducing one adds a manual deploy-and-link step in
Remix that does not currently exist. Flag before adopting rather than doing it silently.

---

## 4. R3-QUOTE — router takes a caller-supplied floor

Mirror `AutoSwapRouterBv4`:

```solidity
function swapExactInputSingleStrict(
    address tokenIn,
    address tokenOut,
    uint24  fee,
    uint128 amountIn,
    uint256 minAmountOut,   // caller-supplied; router does not derive one
    uint256 deadline        // 0 disables
) external returns (uint256 amountOut);
```

- Revert on `minAmountOut == 0` (`ZeroMinOut`) so a caller cannot opt out of a floor.
- Revert on `deadline != 0 && block.timestamp > deadline` (`Expired`).
- Pass `minAmountOut` straight through as `amountOutMinimum`.
- Delete the `IQuoterV2` import, the `quoter` immutable, `strictStrategySlippageBps`, and its
  setter and event. The haircut moves to the strategy, which is the only party that knows the TWAP.
- Add `removeAuthorizedStrategy` and `rescue` (**R3-REVOKE**).

Update `IAutoSwapRouterBv3` to match. The router gets smaller and simpler; it becomes a pure
authorization and execution shim with no opinion about price.

---

## 5. R3-WITHDRAW — derive the floor inside `_swap`

`_swap` computes its own floor from the existing TWAP helpers and passes it down:

```
p = _rebalancePrice1e18()          // TWAP, or 0 when spot is off TWAP / oracle unavailable
if (p == 0) revert                 // fail closed — see §9.1
expectedOut = tokenIn == WETH ? amount * p / 1e18 : amount * 1e18 / p
minOut      = expectedOut * (DIVISOR - swapSlippageBps) / DIVISOR
```

`_rebalancePrice1e18` (line 538) already returns `0` both when the oracle is unusable and when spot
has diverged past `maxTwapDeviationBps`, so the existing deviation gate is reused rather than
duplicated. Watch the orientation: `_price1e18FromSqrt` returns **ASSET per WETH**.

**Path semantics differ deliberately.** `_balanceTokens` keeps its `p == 0` early return and
*skips* — a rebalance can wait. `_payWithdraw` has no such option, since skipping would pay the
user the wrong token, so it **reverts**. That is the accepted trade-off in §9.1.

`swapSlippageBps` is a new strategy-side setting replacing the router's deleted
`strictStrategySlippageBps`, defaulting to `100` to preserve today's effective behaviour.

---

## 6. R3-STAKING — expose `minOutForSwap`

Add to `AutoStrategyBv3`, mirroring `AutoStrategyBv4`:

```solidity
function minOutForSwap(address tokenIn, uint256 amount) external view returns (uint256);
```

Returns the same TWAP-derived floor as §5, or `0` when unavailable. Add it to `IAutoStrategyBv3`.

`ShareStakingBv3` already stores `strategy` (line 31), so both call sites become:

- `notifyReward` (line 316): fetch the floor, and if it is `0`, skip the swap and leave ASSET
  stranded for retry rather than swapping blind. The existing `try/catch` already handles the
  stranding path, so this is a small addition.
- `retryAssetRewardSwap` (line 377): same, but revert on `0` since it is an explicit owner action.

No change to ShareStaking's own storage or authorization.

---

## 7. R3-CONFIG — cap the safety limits

- `AutoStrategyManagerBv3.setMaxTwapDeviationBps` (line 63): cap at `1_000` instead of `DIVISOR`.
  At `DIVISOR` the gate always passes, which silently disables the only real protection.
- New `setSwapSlippageBps`: cap at `1_000`.
- The router's `setStrictStrategySlippageBps` is deleted outright in §4, which removes the
  `minOut == 0` path.

Two-line change in substance; do it in the same pass.

---

## 8. Rejected alternative — moving the TWAP into the router

Considered and rejected as too large a change. Recorded so the trade-offs are not rediscovered:

- **For:** the router is the single chokepoint for *all* callers, so coverage would be automatic and
  future-proof; it has 21,838 bytes spare against the strategy's 1,002; and the swap signature
  would not have needed to change at all.
- **Against:** it is a breaking change for every deployed package (new router, factory, and
  implementations), it needs per-strategy config on the router to avoid handing the router owner a
  global kill switch, and the strategy still needs a TWAP price for `_balanceTokens` sizing and
  `poolValueTwap`, so the oracle could not have left cleanly anyway.

The in-place fix reaches the same security outcome for the two exploitable paths, because `_swap`
is the strategy's internal chokepoint (§2). What it does **not** get is automatic coverage of any
*future* caller added to the router.

---

## 9. Consequences

### 9.1 Accepted risk — deviation blocks exits

Every withdraw path swaps: `outToken == WETH` converts ASSET→WETH, `outToken == ASSET` converts
WETH→ASSET. Once `_swap` reverts on an unusable TWAP, **both directions revert**, so a sustained
deviation blocks all withdrawals. An adversary willing to hold the pool beyond
`maxTwapDeviationBps` can freeze exits while they fund it.

Raised and **accepted**. It is in tension with the "exits always open" principle adopted for the V4
pause work, so it should stay a conscious, documented position.

Trigger threshold in practice: the 30-minute mean tick sits near the midpoint of a trend, so a
sustained move of roughly **6% per 30 minutes** puts spot ~3% off the TWAP and trips the default
300 bps band. That is ordinary volatility for a small-cap, not just an attack scenario. Consider
whether 300 bps is still the right default now that it gates exits and not only rebalances.

**Primary release valve — exits price against a wider band than rebalances.** `_swap` takes the
allowed deviation as a parameter. `_balanceTokens` passes `maxTwapDeviationBps`; `_payWithdraw`
passes `WITHDRAW_DEVIATION_MULTIPLE * maxTwapDeviationBps`, currently **3x**. The asymmetry is
deliberate: a skipped rebalance retries next block at no cost, while a blocked exit strands a user.

This makes the valve automatic — no owner transaction, no incident response, which matters when the
owner is a TBA. At the 300 bps default, exits stay open to 900 bps, so the ~6%-per-30-minutes move
above no longer freezes withdrawals. It is a wider band, not a bypass: the floor is still the TWAP
minus `swapSlippageBps`, so moving spot cannot move the price a sandwich pays.

Two owner-settable valves remain for moves past 3x:

- `setMaxTwapDeviationBps` — widen the band, capped at 1,000 bps, which lifts the exit band to
  3,000 bps. A 15% run therefore still exits, though rebalances stay gated.
- `setTwapSeconds` — shorten the window (min 60s) so the TWAP tracks spot and the deviation
  collapses. Works at any magnitude, at the cost of most of the protection.

**`setTwapSeconds(0)` is now rejected.** Before this change, zero meant "skip gated rebalances" and
was safe. Afterwards it would zero every swap floor and revert every withdrawal, so the obvious
"turn the gate off" lever would have bricked exits. Shortening the window is the supported way to
loosen the gate.

Alternative left on the table: a no-swap pro-rata exit paying both ASSET and WETH needs no oracle
and cannot be frozen. Worth revisiting if the freeze proves unacceptable in testing.

### 9.2 Reward timing

Gated reward swaps strand ASSET for `retryAssetRewardSwap` during volatile periods instead of
executing badly. Correct, but rewards land later.

### 9.3 Gas

Net reduction. A `QuoterV2` full-swap simulation per swap is replaced by one `observe` plus one
`slot0` in the strategy.

### 9.4 Deployment — new strategy and new router must ship together

The signature change moves the function selector:

- Old — `swapExactInputSingleStrict(address,address,uint24,uint128)`
- New — `swapExactInputSingleStrict(address,address,uint24,uint128,uint256,uint256)`

Neither router has a fallback, so a mismatched pair reverts on every swap in either direction.

**The failure is silent at deploy time.** `deployVaultPackage` calls `addAuthorizedStrategy`, whose
selector is unchanged, and `bootstrap` only checks `swapRouter_ != address(0)` without probing the
interface. Pointing a new factory at the old router therefore deploys cleanly, emits its events, and
accepts deposits — then reverts on the first rebalance, harvest, and withdrawal, leaving a funded
vault that cannot trade or pay out.

No on-chain guard was added, to preserve the factory's remaining initcode headroom (§13). Deployment
order is the control:

1. Deploy the new `AutoSwapRouterBv3`.
2. `updateInfra` to point the factory at it.
3. Verify `infra.swapRouter`.
4. Deploy packages.

Already-deployed packages are unaffected — old strategy plus old router keeps working as before,
simply still carrying all five findings until migrated.

---

## 10. Port matrix

Implement on `base-v3`, then port. The twins are byte-identical in the affected code.

| Package | Router | Strategy | ShareStaking | Status |
|---------|--------|----------|--------------|--------|
| `auto-vaults-base-v3` | `AutoSwapRouterBv3` | `AutoStrategyBv3` | `ShareStakingBv3` | **Done** |
| `auto-vaults-rh-v3` | `AutoSwapRouterRhV3` | `AutoStrategyRhV3` | `ShareStakingRhV3` | Pending |
| `auto-vaults-rh-sushi-v3` | `AutoSwapRouterSv3` | `AutoStrategySv3` | `ShareStakingSv3` | Pending |

Out of scope: `ustrategy-*-v3` share the router pattern but are a separate workstream.

---

## 11. Test plan

- `minAmountOut == 0` reverts; a stale `deadline` reverts.
- The floor tracks the TWAP and **not** a manipulated spot: move spot, confirm the floor is
  unchanged and the swap reverts rather than executing at the manipulated rate.
- Sandwiching a withdrawal reverts (**R3-WITHDRAW** regression), both `outToken` directions.
- `_balanceTokens` still **skips** on a bad TWAP while `_payWithdraw` **reverts** (§5).
- `ShareStakingBv3.notifyReward` strands ASSET on a bad TWAP and `retryAssetRewardSwap` recovers it
  (**R3-STAKING**); `retryAssetRewardSwap` reverts rather than stranding.
- `twapSeconds == 0` and insufficient observation cardinality both fail closed.
- Caps enforced on `maxTwapDeviationBps` and `swapSlippageBps` (**R3-CONFIG**).
- `removeAuthorizedStrategy` blocks subsequent swaps.
- `forge build --sizes`: record `AutoStrategyBv3` runtime margin (§3).

---

## 12. Pre-existing blocker

`forge build` under profile `base-v3` currently **fails**: `UFloatStrategyV4` exceeds EIP-170 by 322
bytes. It belongs to `contracts/ustrategy-base-v4` and is pulled in through the shared `test`
directory. Unrelated, but the profile does not build clean until resolved.

---

## 13. Outcome (base-v3)

Sizes before → after:

| Contract | Before | After | Delta | Margin left |
|----------|--------|-------|-------|-------------|
| `AutoStrategyBv3` runtime | 23,574 | 23,998 | +424 | **578** to EIP-170 |
| `AutoFactoryBv3` initcode | 48,150 | 48,941 | +791 | **211** to EIP-3860 |
| `AutoSwapRouterBv3` runtime | 2,738 | 2,509 | −229 | 22,067 |
| `ShareStakingBv3` runtime | 7,385 | 7,731 | +346 | 16,845 |

The last +98 on each of the strategy and the factory is the widened withdraw band (§9.1). Folding
`_spotAlignedWithTwap` into a band-parameterised `_priceWithinBand` paid for most of it.

The factory is the binding constraint, not the strategy: it deploys all four implementations in its
own constructor, so their creation code is embedded in its initcode and **211 bytes is the shared
budget across the strategy, vault, LiquidShares, and ShareStaking.** A user-supplied `minOut` on
`withdraw` was costed at roughly 400–800 bytes and does not fit without extracting a library first.

**No linked libraries were needed** — escape hatch (1) in §3 was sufficient, so the stack still deploys
with no linking step.

The binding constraint moved from the strategy to the **factory**, which now has 291 bytes of
initcode headroom. The factory carries the creation code of both the strategy (+365) and
ShareStaking (+346), so growth in either propagates into it. Any further additions to those two
contracts should be size-checked against `AutoFactoryBv3` first, not the strategy.

Tests: 86 pass (63 pre-existing plus 23 new across `test/AutoSwapRouterBv3.t.sol` and
`test/SwapFloorBv3.t.sol`).

---

## 14. Change log

| Date | Change |
|------|--------|
| 2026-08-31 | Plan created for router-side TWAP migration. |
| 2026-08-31 | Rewritten: TWAP stays in the strategy; in-place fix mirroring the V4 router hardening. |
| 2026-08-31 | Implemented on `base-v3`. All five findings closed; 84 tests pass. No linked libraries needed — see §13. |
| 2026-08-31 | `setTwapSeconds(0)` rejected — it would have zeroed every swap floor and bricked withdrawals (§9.1). 86 tests. |
| 2026-08-31 | Exits price against 3x the rebalance band as an automatic release valve (§9.1). 90 tests. |
