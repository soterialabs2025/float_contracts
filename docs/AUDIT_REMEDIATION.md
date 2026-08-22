# AutoVault audit remediation reference

Technical reference for SolidityScan findings on AutoVault Bv4 package contracts (strategy + vault) and follow-up remediations. Use this when porting the same fixes across packages.

**Scopes:**
- `AutoStrategyBv4` — primary scan 21 Aug 2026
- `AutoVaultBv4` — vault findings tracked below (same workstream)
- `AutoFactoryBv4` — factory findings tracked below
- `ShareStakingBv4` — staking findings tracked below
- `LiquidSharesBv4` — share token findings tracked below

**Related review canvas:** Cursor canvases `auto-strategy-bv4-audit-review.canvas.tsx`  
**Tracking rule:** Every code change and every report disposition from this audit workstream must update (1) the disposition table(s) and (2) the change log at the bottom of this file.

---

## Package matrix (port targets)

| Package | Strategy | Vault | W1 withdraw | Notes |
|---------|----------|-------|-------------|-------|
| `auto-vault-base-v4` | `AutoStrategyBv4` | `AutoVaultBv4` | **Done** | WETH wrap |
| `auto-vault-rh-v4` | `AutoStrategyRhV4` | (RH vault) | Pending | Native ETH |
| `auto-vaults-base-v3` | `AutoStrategyBv3` | | Pending | |
| `auto-vaults-rh-v3` | `AutoStrategyRhV3` | | Pending | |
| `auto-vaults-rh-sushi-v3` | `AutoStrategySv3` | | Pending | |

---

## Factory findings (`AutoFactoryBv4`)

| ID | Severity | Title | Disposition | Status |
|----|----------|-------|-------------|--------|
| **F-AC-TPO** | Info | Incorrect AC on `transferPackageOwnership` | **False positive** — requires package owner or factory owner; lock/mismatch checks | Won’t Fix — reported |
| **F-REENTRANCY** | Low / Info | Reentrancy on `deployVaultPackage` | **Agree CEI** — added `nonReentrant` | **Fixed** |
| **F-EVENTS** | Info | Missing event on `updateInfra` | **Agree** — emit `InfraUpdated` | **Fixed** |
| **F-EVENT-REENTRANCY** | Info | Events after external calls on deploy / transfer ownership | **False positive / mitigated** — both fns `nonReentrant`; emit only after successful setup (do not emit on revert) | Won’t Fix — reported |

---

## ShareStaking findings (`ShareStakingBv4`)

| ID | Severity | Title | Disposition | Status |
|----|----------|-------|-------------|--------|
| **S-BOOTSTRAP** | Medium (code) / Low (ops) | `bootstrap` callable by anyone once | **Agree** — gated to immutable `factory` | **Fixed** |
| **S-RESCUE** | High / Medium | `rescueToken` can drain liquidShares / asset | **Agree** — removed `rescueToken` (no owner path to user funds); stranded asset via `retryAssetRewardSwap` only | **Fixed** |
| **S-PRECISION** | Info | Precision loss on division | **False positive / accepted** — `Math.mulDiv` floors; dust stays in pots; epoch index floor intentional | Won’t Fix — reported |
| **S-TRYCATCH** | Info / Low | try/catch limitations on ASSET→WETH swap | **Agree as Low** — intentional soft-fail; trusted router; retry via `retryAssetRewardSwap` | Won’t Fix — reported |
| **S-EVENTS-TOF** | Info | Missing event on `transferOwnershipFromFactory` | **False positive** — OZ `OwnershipTransferred` via `_transferOwnership`; factory also emits `PackageOwnershipTransferred` | Won’t Fix — reported |
| **S-EVENTS-ADMIN** | Info | Missing events on reward settings / rescue | **Product choice** — no admin events; state readable on-chain | Won’t Fix — removed |
| **S-EVENTS-INTERNAL** | Info | Missing events on `_lockToCurrentEpochEnd` / `_takeOwnerEpochCut` / `_swapAssetToWeth` | **False positive** — covered by `Staked` / `EpochFinalized` / `RewardNotified` | Won’t Fix — reported |
| **S-NONREENTRANT-ORDER** | Info | `nonReentrant` after `onlyOwner` on `retryAssetRewardSwap` | **Agree style** — reorder to `nonReentrant onlyOwner` | **Fixed** |
| **S-AC-STAKE** | Info | Missing `onlyOwner` on `stake` | **False positive** — public user stake is intentional; Ownable is for admin, not staking | Won’t Fix — reported |

---

## LiquidShares findings (`LiquidSharesBv4`)

| ID | Severity | Title | Disposition | Status |
|----|----------|-------|-------------|--------|
| **L-BOOTSTRAP** | Medium (code) / Low (ops) | `initialize`/`bootstrap` callable by anyone once | **Agree** — gated to immutable `factory` (parity vault/strategy/staking) | **Fixed** (pre-audit) |
| **L-APPROVE-RACE** | Info / Low | ERC20 approve allowance race | **Accepted ERC20 behavior** — same as OZ ERC20; use `approve(0)` then set, or max allowance | Won’t Fix — reported |
| **L-AC-BURN** | Info | Public `burn(from)` missing onlyOwner / burns non-msg.sender | **False positive** — `msg.sender == vault` only; vault burns depositor shares on redeem | Won’t Fix — reported |

---

## Vault findings (`AutoVaultBv4`)

| ID | Severity | Title | Disposition | Status |
|----|----------|-------|-------------|--------|
| **V-PAUSE** | Medium / Design | Improper Pausable — no owner `pause`/`unpause` | **Product choice** — removed `Pausable` entirely (no emergency pause) | **Fixed** — removed |
| **V-BOOTSTRAP** | Medium (code) / Low (ops) | `bootstrap` callable by anyone once | **Agree** — gated to immutable `factory` | **Fixed** |
| **V-AC-DEPOSIT** | Info | Incorrect AC on `depositETH` | **False positive** — public deposit is intentional; `nonReentrant` + `msg.value` | Won’t Fix — reported |
| **V-AC-RECEIVE** | Info | Incorrect AC on `receive()` | **False positive / N/A** — always reverts; forces ETH via `depositETH` only | Won’t Fix — reported |
| **V-AC-WITHDRAW** | Info | Incorrect AC on `withdraw` | **False positive** — burns `msg.sender` shares only; intentional public redeem | Won’t Fix — reported |
| **V-AC-TOF** | Info | Incorrect AC on `transferOwnershipFromFactory` | **False positive** — factory-only + zero + lock checks | Won’t Fix — reported |
| **V-NAV-MINT** | Medium | Share minting from `strategy.balance()` delta (manipulable NAV) | **Agree** — cap `credited` to `amount` | **Fixed** (partial; full TWAP NAV still H001-W3) |
| **V-OWNABLE2STEP** | Info | Prefer Ownable2Step over Ownable | Style/safety tip; conflicts with one-shot factory/`ownershipLocked` flow | Won’t Fix — reported |
| **V-EVENT-INDEX** | Info | Missing `indexed` on some event params | Indexing hygiene | **Fixed** — `asAsset`, snapshot `timestamp` indexed |
| **V-BLOCK-TIME** | Info | `block.timestamp` as time proxy (snapshots) | Telemetry only; not settlement-critical | Won’t Fix — reported |

### V-PAUSE detail

Originally: OZ `Pausable` + `whenNotPaused` on deposit/withdraw without owner `pause`/`unpause` (dead switch).

**Final product choice:** remove `Pausable` entirely — no emergency pause on vault deposits/withdrawals. Deposits/withdraws remain `nonReentrant` only.

~~Prior remediations: add `pause()`/`unpause()` `onlyOwner`.~~ Reverted in favor of removal.

### V-BOOTSTRAP detail

**Fixed:** `factory` is `immutable`, set in `AutoVaultBv4(factory_)` when the factory deploys the implementation (`new AutoVaultBv4(address(this))`). EIP-1167 clones copy that immutable. `bootstrap` requires `msg.sender == factory` (parity with strategy).

**Port:** apply same pattern to other package vaults if they still use unrestricted once-only bootstrap.

### V-NAV-MINT detail

`_mintSharesAndDeploy` does:
```
navBefore = strategy.balance()   // spot-valued LP + idle
strategy.deposit(amount)
navAfter = strategy.balance()
credited = navAfter - navBefore
shares = credited * supply / navBefore   // (or amount if first deposit)
```

`strategy.balance()` → `poolValue()` uses slot0 spot for ASSET↔WETH. Any NAV increase between the two reads (sandwich / existing LP mark-to-market) is attributed entirely to the depositor → possible **overmint**.

**Not the same as V-AC-WITHDRAW** (ACL is fine). Related to strategy H001-W3.

**Fix applied:** `if (credited > amount) credited = amount;` in `_mintSharesAndDeploy` — blocks overmint from NAV jumps between the two `balance()` reads. Depositor can still receive fewer shares if internal strategy swaps lose value (`credited < amount`).

**Remaining:** longer-term manipulation-resistant NAV (H001-W3 / TWAP) if needed beyond the cap.

---

## Strategy findings (`AutoStrategyBv4`) — disposition (vendor → ours)


| ID | Severity | Title | Disposition | Status |
|----|----------|-------|-------------|--------|
| **H001** | High | Spot-driven rebalance / withdraw math | **Agree**. Split W1/W2/W3 | **W1 Fixed** on Bv4; W2/W3 pending |
| **H-PARTIAL-FEE** | Medium | Partial withdraw collects Uni fees with `trackFees=false` | **Agree** — `_collectAllFees(true)` before partial decrease | **Fixed** |
| **H002** | High | Claim reward NFT ownership | **False positive** (`harvestBoolean`) | Won’t Fix — reported |
| **M001** | Medium | try/catch limitations | **Agree as Low**; intentional soft-fail | Won’t Fix — reported |
| **M002** | Medium | Missing approve return validation | **False positive** (`forceApprove` + Permit2 void `approve`) | Won’t Fix — reported |
| **M003** | Medium | Non-standard ERC20 | **Agree if FoT/rebase**; allowlist constraint | Won’t Fix — reported |
| **L001** | Low | Approving maximum value | Uni POSM/Permit2 trust | Won’t Fix — reported |
| **L002** | Low | Empty try/catch | Same as M001 | Won’t Fix — reported |
| **L003** | Low | Floating pragma `^0.8.20` | Foundry pins Solc **0.8.25** | Won’t Fix — reported |
| **L004** | Low | Legacy `.selector` side-effects bug | No side effects; build uses `via_ir` | Won’t Fix — reported (FP) |
| **L005** | Low | Missing events | Info / indexing only | Won’t Fix — reported |
| **L006** | Low | Missing zero-address validation | See instance table below | Won’t Fix — reported |
| **L007** | Low | Outdated compiler version | Builds with 0.8.25 | Won’t Fix — reported |
| **I-natspec-ctor** | Info | Missing `@notice` on constructor | Style | **Fixed** |
| **I-natspec-scope** | Info | Missing NatSpec on unnamed scope blocks (43) | Style noise | Won’t Fix — reported |
| **I001** | Info | Redundant `return` with named returns (`balanceOfPool`) | Style | **Fixed** — assign named returns |
| **I-natspec-dev-fn** | Info | Missing `@dev` on functions (41) | Style / maintainability only | Won’t Fix — reported |
| **I-natspec-dev-contract** | Info | Missing `@dev` on contract declaration | Style — already has `@title`/`@notice` | Won’t Fix — reported |
| **I-inheritdoc** | Info | Missing `@inheritdoc` on overrides | Style / docs consistency | Won’t Fix — reported |
| **I-ternary** | Info | Prefer ternary over if/else (e.g. reserve peel) | Style — keep if/else for clarity | Won’t Fix — reported |
| **I-block-time** | Info | `block.timestamp` / `block.number` as time proxy | Standard for harvest delay; not precise settlement | Won’t Fix — reported |
| **I-delete-zero** | Gas | Prefer `delete` over assigning `0` | `delete` ≡ `= 0` for integers; no material win | Won’t Fix — reported |
| **I-zero-to-one** | Gas | Avoid zero→nonzero storage writes (1/2 sentinel pattern) | **Unsafe** for timestamps, reserves, bools here — do not apply | Won’t Fix — reported (reject) |
| **I-restore-same** | Gas | Skip SSTORE when old == new | Optional micro-opt; safe if careful; low value | Won’t Fix — reported |
| **I-neq-zero** | Gas | Prefer `!= 0` over `> 0` for uints | Micro-opt; optimizer/`via_ir` often equalizes | Won’t Fix — reported |
| **I-inequality** | Gas | Prefer `>=`/`<=` over `>`/`<` in ifs | **Do not bulk-apply** — can change semantics | Won’t Fix — reported (reject blind rewrite) |
| **I-storage-cache** | Gas | Cache storage vars in memory (45) | Optional micro-opt; correctness-sensitive if wrong | Won’t Fix — reported |
| **I-named-return** | Gas | Named return vs `return` local (`_calculateLiquidityToRemove`) | Function **removed** in H001-W1 | **N/A / Fixed** by deletion |
| **I-split-revert** | Gas | Split multi-condition `if (...) revert` | Style/gas noise; short-circuit already helps | Won’t Fix — reported |
| **I-constant-state** | Gas | Mark never-modified state as `constant` | Immutables/constants already used where valid; bootstrap-set vars cannot be | Won’t Fix — reported |
| **I-multi-operand-if** | Gas | Multiple operands in one if/else-if | Short-circuit exists; nesting ≠ free win | Won’t Fix — reported |
| **I-bool-bitmap** | Gas | Bitmaps instead of multiple bools | Compiler may pack; manual bitmaps hurt clarity/safety | Won’t Fix — reported |
| **I-inline-once** | Gas | Inline internals called once | Optional; size/stack risk on this strategy | Won’t Fix — reported (reject sweep) |
| **I-payable-ctor** | Gas | Mark constructor `payable` to save opcodes | Tiny gas; risk of stranded ETH at deploy | Won’t Fix — reported |
| **I-this-selector** | Gas | `this.onERC721Received.selector` wastes external-call gas | **FP** — `.selector` is not an external CALL | Won’t Fix — reported |
| **I-unused-internal** | Gas/Info | Internal never used (`_stakingShareBpsEditable`) | **FP** — override called from manager base | Won’t Fix — reported |
| **I-revert-dos** | Info | Reverts in public/external = DoS (14) | **FP / by design** — auth & validation reverts | Won’t Fix — reported |
| **I-natspec-pub-var** | Info | Missing NatSpec on public variables | Style / ABI docs only | Won’t Fix — reported |
| **I-unnamed-params** | Info | Unnamed function parameters (`onERC721Received`) | Style — unused IERC721Receiver args | Won’t Fix — reported |
| **I-uint48-time** | Info / Gas | Prefer `uint48` for time vars (`lastRebalanceTime`, etc.) | Gas micro-opt; packing not free | Won’t Fix — reported |
| **I-underscore** | Info | Missing underscore on private vars | Style | **Partial Fixed** (`_feeManager`, `_shareStaking`, `_bootstrapped`); remainder Won’t Fix |
| **AC-*** | Info | “Incorrect AC” (each concludes valid) | Confirmatory, not bugs | Accept — reported |
| Other I/Gas | — | NatSpec noise, gas micros, etc. | Noise | Ignore / Won’t Fix as filed |

### L006 zero-address instances (Bv4)

| Location | Target | Call |
|----------|--------|------|
| ctor `factory_` | No explicit `!= 0` | Won’t Fix — zero factory cannot bootstrap |
| `transferOwnership` | No local zero check | FP — OZ `Ownable` rejects zero |
| `_routeProtocolFee(token)` | No check on `token` | FP — only ASSET/WETH from fee collect; staking/feeManager set at bootstrap |

### Access-control scan notes (not findings)

Entries that state control is **valid** (bootstrap factory-once, `transferOwnershipFromFactory`, keeper/harvest → `_onlyKeeper`, deposit/withdraw → `_onlyVault`, `setWatched` → keeper|factory|owner). **No fix.**

Nuance for auditors: `_onlyKeeper` also allows **registry operators**, **owner**, and `address(this)` — intentional (**F4**).

### Internal findings (scanner missed; still track)

| ID | Issue | Disposition | Status |
|----|-------|-------------|--------|
| **F1** | Inner-band remint while still in outer range | Ops / band params; optional remint-on-outer-only | Pending (config first) |
| **F2** | Bv4 band setters lack `requireSpacedTicks` (RhV4 has it) | Parity harden | Pending |
| **F3** | Uncapped `reserveBps` / `targetAssetBps` | Trusted owner; optional caps | Pending |
| **F4** | `_onlyKeeper` includes operators + owner | Intentional ops | Accept / document |
| **F5** | Same as M001 | | Won’t Fix (aligned with M001) |
| **F6** | Partial withdraw approximate (swap/slippage) | Disclose; W1 fixed sizing | Accept |
| **F7** | Infinite POSM/Permit2 allowances | Uni trust (= L001) | Accept |
| **F8** | Pool hooks chosen at deploy | Operator diligence | Accept |

---

## H001 workstreams

H001 is one finding, three layers. Do **not** treat “add TWAP everywhere” as the only fix.

### W1 — Withdraw LP sizing without spot (**DONE** on Bv4)

**Problem:** Partial withdraw used `_poolValueOnly()` (slot0) then `_calculateLiquidityToRemove(amountWeth)` (slot0 again) to decide how much Uniswap liquidity to burn.

**Fix:**

```solidity
uint256 liqToRemove = Math.mulDiv(uint256(liquidity), userShares, totalSupply_);
if (liqToRemove == 0 && userShares > 0) liqToRemove = 1; // dust hardener
if (liqToRemove > liquidity) liqToRemove = liquidity;
_decreaseLiquidityInternal(uint128(liqToRemove), false);
```

**Cleanup:** removed `_decreaseLiquidity(uint256)`, `_calculateLiquidityToRemove`.  
**Keep:** `_decreaseLiquidityInternal`, `_poolValueOnly`, `poolValue()`, `balanceOfPool()`.

**Reference:** `contracts/auto-vault-base-v4/AutoStrategyBv4.sol` → `withdraw()`.

#### What the withdrawer is owed (unchanged formula)

```
owedAsset = (assetBalAfter - idleAssetBefore) + idleAssetBefore * shares / supply
owedWeth  = (wethBalAfter  - idleWethBefore)  + idleWethBefore  * shares / supply
```

Then `_consumeReservedShare` → `_payWithdraw` (fee → optional swap → transfer).

#### OOR behavior (not a W1 regression)

OOR burn returns mostly one token; `_payWithdraw` may swap to requested `WithdrawToken`. Uni mechanics; W1 only changed burn **size**.

#### Port checklist (W1)

1. Find `poolVal` / `_calculateLiquidityToRemove` partial withdraw.
2. Replace with `L * shares / supply` + dust `→ 1` + cap.
3. Remove dead helpers; keep `poolValue`.
4. Compile; smoke in-range, OOR, full exit.
5. Port RhV4 / Bv3 / RhV3 / Sv3.

---

### W2 — Remint / `_balanceTokens` spot targeting (**PENDING**)

Options: (A) skip pre-balance swap, (B) deadband, (C) TWAP via oracle hook + router helper.  
**V4 has no core TWAP** — only oracle hooks. Router minOut ≠ trusted allocation price.

### W3 — Optional NAV / deposit oracle (**PENDING**)

Vault still mints shares from `strategy.poolValue()` (slot0). After W1+W2 if needed.

---

## Other remediations (future)

- **F2:** Add `TrailingFloorLib.requireSpacedTicks` to Bv4 manager (match RhV4).
- **F1:** Widen inner / keeper interval; optional remint-on-outer-only.
- **F3:** Optional cap `reserveBps` / `targetAssetBps` to `DIVISOR`.
- **M001:** Optional require notify / pull-back (currently Won’t Fix).

---

## Trust surfaces (accept unless threat model changes)

- Infinite approvals to Position Manager / Permit2.
- Pool hooks at deploy.
- Operators + owner on `_onlyKeeper`.
- Bv4 manager: withdrawal/protocol fee / slippage / minHarvestDelay frozen at `_initAutoDefaults` (no setters).

---

## Change log

| Date | Change | Contracts / notes |
|------|--------|-------------------|
| 2026-08-21 | **H001-W1 Fixed:** liquidity-proportional partial withdraw + dust hardener; remove `_decreaseLiquidity` / `_calculateLiquidityToRemove` | `AutoStrategyBv4` |
| 2026-08-21 | **H-PARTIAL-FEE Fixed:** partial LP exit calls `_collectAllFees(true)` before decrease (protocol/reserve skim) | `AutoStrategyBv4` |
| 2026-08-21 | Created this remediation doc | `docs/AUDIT_REMEDIATION.md` |
| 2026-08-21 | Report dispositions drafted: H002 FP, AC-\* accept, M002 FP, M001/L002 Won’t Fix, M003 Won’t Fix (allowlist), L001 Won’t Fix, L003/L007 Won’t Fix (Solc 0.8.25), L004 FP, L005 Won’t Fix, L006 Won’t Fix (per-instance) | report only |
| 2026-08-21 | **I-natspec-ctor Fixed:** `@notice` on constructor | `AutoStrategyBv4` |
| 2026-08-21 | **I-underscore Partial Fixed:** rename `feeManager`→`_feeManager`, `shareStaking`→`_shareStaking`, `bootstrapped`→`_bootstrapped` | `AutoStrategyBv4` |
| 2026-08-21 | **I-natspec-scope Won’t Fix:** 43× missing NatSpec on unnamed scope blocks (style noise) | report only |
| 2026-08-21 | **I001 Fixed:** `balanceOfPool` uses named return assignment instead of explicit `return` | `AutoStrategyBv4` |
| 2026-08-21 | **I-natspec-dev-fn Won’t Fix:** 41× missing `@dev` on functions | report only |
| 2026-08-21 | **I-revert-dos Won’t Fix:** 14× reverts in public/external flagged as DoS (auth/validation by design) | report only |
| 2026-08-21 | **I-natspec-pub-var Won’t Fix:** missing NatSpec on public variable declarations | report only |
| 2026-08-21 | **I-unnamed-params Won’t Fix:** `onERC721Received` unused IERC721Receiver params left unnamed | report only |
| 2026-08-21 | **I-uint48-time Won’t Fix:** keep `uint256` for time vars (`lastRebalanceTime`, etc.) | report only |
| 2026-08-21 | **I-natspec-dev-contract Won’t Fix:** missing `@dev` on contract declaration (has `@title`/`@notice`) | report only |
| 2026-08-21 | **I-inheritdoc Won’t Fix:** missing `@inheritdoc` on override functions | report only |
| 2026-08-21 | **I-ternary Won’t Fix:** keep if/else vs ternary for reserve peel clarity | report only |
| 2026-08-21 | **I-block-time Won’t Fix:** `block.timestamp` for harvest/rebalance timing is acceptable | report only |
| 2026-08-21 | **I-delete-zero Won’t Fix:** assigning `0` vs `delete` for ints is equivalent | report only |
| 2026-08-21 | **I-zero-to-one Won’t Fix (reject):** ReentrancyGuard 1/2 pattern must not be applied to timestamps/reserves/bools | report only |
| 2026-08-21 | **I-restore-same Won’t Fix:** skip equal SSTORE is optional gas only; bootstrap mostly FP | report only |
| 2026-08-21 | **I-neq-zero Won’t Fix:** `> 0` vs `!= 0` for uints is micro gas / style | report only |
| 2026-08-21 | **I-inequality Won’t Fix (reject blind):** `>=` vs `>` rewrites can change behavior | report only |
| 2026-08-21 | **I-storage-cache Won’t Fix:** 45× storage caching-in-memory gas tips | report only |
| 2026-08-21 | **I-named-return N/A:** `_calculateLiquidityToRemove` removed with H001-W1 | `AutoStrategyBv4` |
| 2026-08-21 | **I-split-revert Won’t Fix:** multi-condition `if` + revert gas tip | report only |
| 2026-08-21 | **I-constant-state Won’t Fix:** constant/immutable already applied where language allows | report only |
| 2026-08-21 | **I-multi-operand-if Won’t Fix:** compound if conditions; Solidity short-circuits `&&`/`||` | report only |
| 2026-08-21 | **I-bool-bitmap Won’t Fix:** keep discrete bools vs manual bitmap packing | report only |
| 2026-08-21 | **I-inline-once Won’t Fix (reject sweep):** single-call internals kept for size/clarity/stack | report only |
| 2026-08-21 | **I-payable-ctor Won’t Fix:** non-payable constructor; avoid accidental ETH at deploy | report only |
| 2026-08-21 | **I-this-selector Won’t Fix (FP):** `this.onERC721Received.selector` is not an external call | report only |
| 2026-08-21 | **I-unused-internal Won’t Fix (FP):** `_stakingShareBpsEditable` override used by manager | report only |
| 2026-08-21 | **V-PAUSE Agree / Pending:** `AutoVaultBv4` inherits Pausable + `whenNotPaused` but no owner `pause`/`unpause` | `AutoVaultBv4` — report; code TBD |
| 2026-08-21 | **V-PAUSE Fixed:** add `pause()` / `unpause()` `onlyOwner` | `AutoVaultBv4` |
| 2026-08-21 | **V-PAUSE Removed:** drop `Pausable`, `whenNotPaused`, and `pause`/`unpause` (product choice) | `AutoVaultBv4` |
| 2026-08-21 | **V-BOOTSTRAP Agree:** vault `bootstrap` unrestricted once; atomic factory mitigates; harden optional | `AutoVaultBv4` — report |
| 2026-08-21 | **V-BOOTSTRAP Fixed:** immutable `factory` + `msg.sender == factory` in bootstrap; factory ctor `new AutoVaultBv4(address(this))` | `AutoVaultBv4`, `AutoFactoryBv4` |
| 2026-08-21 | **V-AC-DEPOSIT Won’t Fix (FP):** `depositETH` public by design; reentrancy/pause guards present | report only |
| 2026-08-21 | **V-AC-RECEIVE Won’t Fix (FP):** `receive()` always reverts; no AC needed | report only |
| 2026-08-21 | **V-AC-WITHDRAW Won’t Fix (FP):** `withdraw` redeems only `msg.sender` shares | report only |
| 2026-08-21 | **V-AC-TOF Won’t Fix (FP):** `transferOwnershipFromFactory` correctly factory-gated | report only |
| 2026-08-21 | **V-BOOTSTRAP Fixed (report):** first-caller takeover closed by immutable factory + `msg.sender == factory` | already in code; confirm on re-scan |
| 2026-08-21 | **V-NAV-MINT Agree / Pending:** share mint uses strategy NAV delta; spot sandwich can overmint | `AutoVaultBv4` — report; fix TBD |
| 2026-08-21 | **V-NAV-MINT Fixed (cap):** `credited = min(credited, amount)` in `_mintSharesAndDeploy` | `AutoVaultBv4` |
| 2026-08-21 | **V-OWNABLE2STEP Won’t Fix:** keep Ownable + factory one-shot + ownershipLocked | report only |
| 2026-08-21 | **V-EVENT-INDEX Won’t Fix:** event indexed params are sufficient for filters | report only |
| 2026-08-21 | **V-EVENT-INDEX Fixed:** index `Withdraw.asAsset`, `PoolValueSnapshotRecorded.timestamp` | `AutoVaultBv4` |
| 2026-08-21 | **V-BLOCK-TIME Won’t Fix:** snapshot uses `block.timestamp` for telemetry only | report only |
| 2026-08-21 | **F-AC-TPO Won’t Fix (FP):** `transferPackageOwnership` correctly gated to package owner or factory owner | report only |
| 2026-08-21 | **F-REENTRANCY Won’t Fix:** `deployVaultPackage` CEI noted; trusted clones + onlyOperator | report only |
| 2026-08-21 | **F-REENTRANCY Fixed:** `ReentrancyGuard` + `nonReentrant` on `deployVaultPackage` and `transferPackageOwnership` | `AutoFactoryBv4` |
| 2026-08-21 | **F-EVENTS Fixed:** `InfraUpdated` emitted from `updateInfra` | `AutoFactoryBv4` |
| 2026-08-21 | **F-EVENT-REENTRANCY Won’t Fix:** events after calls intentional; reentrancy covered by `nonReentrant` | report only |
| 2026-08-21 | **S-BOOTSTRAP Fixed:** immutable `factory` + `msg.sender == factory` in bootstrap; factory ctor `new ShareStakingBv4(address(this))` | `ShareStakingBv4`, `AutoFactoryBv4` |
| 2026-08-21 | **S-RESCUE Fixed:** `rescueToken` reverts on liquidShares/asset; WETH still surplus above `accountedWeth` | `ShareStakingBv4` |
| 2026-08-21 | **S-RESCUE:** removed `rescueToken` entirely (Bv4 + ported packages); retry swap remains | `ShareStaking*` |
| 2026-08-21 | **S-PRECISION Won’t Fix:** integer division / mulDiv floor accepted; dust remains in reward pots | report only |
| 2026-08-21 | **S-TRYCATCH Won’t Fix:** soft-fail swap intentional; parity with strategy M001 | report only |
| 2026-08-21 | **S-EVENTS-TOF Won’t Fix (FP):** TOF already emits OZ `OwnershipTransferred`; factory package event covers ops | report only |
| 2026-08-21 | **S-EVENTS-ADMIN Fixed:** `OwnerRewardBpsUpdated`, `OwnerRewardRecipientUpdated`, `TokenRescued` | `ShareStakingBv4` |
| 2026-08-21 | **S-EVENTS-ADMIN Removed:** drop those admin events (product choice) | `ShareStakingBv4` |
| 2026-08-21 | **S-EVENTS-INTERNAL Won’t Fix (FP):** lock/cut/swap covered by existing stake/finalize/notify events | report only |
| 2026-08-21 | **S-NONREENTRANT-ORDER Fixed:** `retryAssetRewardSwap` → `nonReentrant onlyOwner` | `ShareStakingBv4` |
| 2026-08-21 | **S-AC-STAKE Won’t Fix (FP):** `stake` must be public; Ownable ≠ stake gate | report only |
| 2026-08-21 | **L-BOOTSTRAP Fixed (pre-audit):** immutable `factory` + `msg.sender == factory` on `initialize`; factory ctor `new LiquidSharesBv4(address(this))` | `LiquidSharesBv4`, `AutoFactoryBv4` |
| 2026-08-21 | **L-APPROVE-RACE Won’t Fix:** standard ERC20 approve race; no custom change | report only |
| 2026-08-21 | **L-AC-BURN Won’t Fix (FP):** `burn` is vault-only; burns `from` on redeem by design | report only |
| | **Pending code:** H001-W2, H001-W3, F2, F1 (optional), W1 ports, V-NAV-MINT ports | TBD |

Update this table on every audit-related code change or final report disposition.
