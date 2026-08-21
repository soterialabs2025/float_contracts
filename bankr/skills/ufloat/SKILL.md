---
name: ufloat
description: >-
  Deploy and manage Float UFloatStrategyV4 on Base — deploy via
  UFloatStrategyFactoryV4 with a token allowlist (default mint params), then
  read NAV / mode / ASSET, deposit ETH, withdraw WETH, rotate assets
  (changeAsset / mintPosition / exitToStable), and tune setMintParams /
  setOffensiveParams. Use when the user asks to deploy a UFloat strategy, or
  pastes a strategy address for value, deposit, withdraw, allowlist, rotation,
  or mint parameters. Not for Auto vaults.
tags: [defi, float, ufloat, strategy, base, uniswap-v4]
version: 1
visibility: private
metadata:
  clawdbot:
    emoji: "🫧"
    homepage: "https://docs.bankr.bot/skills/in-bankr/skill-format"
---

# UFloat Strategy (Base)

Chain: **Base** (`8453`).

Owner-managed Uniswap v4 strategy clone. **No vault / no shares.**

| Contract | Address |
|----------|---------|
| UFloatStrategyFactoryV4 | `0xC6e260F7DCff98426c8652eED85315DB3965409A` |
| UFloatSwapRouter (preflight only) | `0x45cb7972Fb88127435d4791eAb034f07ED53064a` |
| WETH (withdraw payout) | `0x4200000000000000000000000000000000000006` |

Per-user **strategy** addresses are not fixed — deploy returns one, or the user pastes an existing one. Never invent a strategy address.

See `references/abi-and-calls.md` for ABI snippets.

## Core rules

1. **Deploy:** use the factory flow below. **Manage:** require a user-pasted or just-deployed **strategy** address.
2. Before owner writes, prefer `owner() ==` connected wallet; if not owner, do not send owner-only txs.
3. **Deposit = ETH only** via `depositETH()` (msg.value). Never deposit WETH/ASSET ERC-20s.
4. **Withdraw = WETH only** via `withdrawWeth`. User receives WETH, not native ETH and not ASSET.
5. Token args are **asset token addresses**, not names.
6. Deploy uses **default mint parameters** on-chain — do not pass custom mint params at deploy. Tune afterward with `setMintParams` / `setOffensiveParams`.

---

## Deploy

**Triggers:** “deploy ufloat strategy”, “create a ufloat”, “new ufloat strategy”, etc.

### Conversation flow

1. Ask: **“Which token addresses do you want in the strategy?”**  
   - Collect one or more ERC-20 asset addresses (not WETH).  
   - Order matters: **`tokens[0]` becomes the initial `ASSET`**.  
   - Confirm the list back to the user before sending a tx.
2. Do **not** ask for mint params at deploy — defaults are applied on-chain.
3. Default `stratMethod = 0` (`ReBalanceOnly`) unless the user explicitly picks another (`1=OffensiveOnly`, `2=DefensiveOnly`, `3=OffensiveDefensive`).
4. Preflight each token on the router:
   - `UFloatSwapRouter.hasV4PoolConfig(token)` must be `true`.  
   - If any is `false`, stop and tell the user that token is not configured on the UFloat router (cannot deploy until it is).
5. Send:
   ```
   factory.deployStrategy(stratMethod, tokens)
   ```
   Caller becomes strategy **owner**.
6. From the tx receipt / return data, record `(strategy, keeperId)`.  
   Echo **strategy address**, initial **ASSET** (`tokens[0]`), allowlist, and `keeperId`.
7. Tell the user they can now:
   - `depositETH`
   - tune bands with `setMintParams` / `setOffensiveParams` (see below)
   - manage assets (`addAllowedToken`, `changeAsset`, …)

If the user already has a strategy address and only wants to manage it, skip deploy.

---

## Reads

Connected wallet = `user`. All calls on `strategy`.

| User prompt | Call |
|-------------|------|
| "What is my strategy worth?" / NAV / pool value | `totalValueWeth()` (WETH-notional, 18 decimals) |
| "What is in the pool?" | `balanceOfPool()` → `(assetAmt, wethAmt)` |
| "How much idle?" | `balanceOfIdle()` |
| "What is the current ASSET?" | `ASSET()` |
| "What tokens are allowed?" | `allowedTokenCount()` + `allowedTokens(i)` |
| "What mode is it in?" | `mode()` → `0=NORMAL`, `1=DEFENSIVE`, `2=OFFENSIVE`, `3=STABLE` |
| "Who owns this strategy?" | `owner()` |
| "Position NFT id?" | `getPositionId()` |

---

## Deposit

**"Deposit X ETH into strategy 0xSTRATEGY"**

1. Confirm `owner() == user`.
2. Convert `X` ETH → wei (`X * 1e18` if human ETH).
3. Send: `strategy.depositETH()` with `value = wei`.
4. Reply with tx hash; optionally re-read `totalValueWeth()`.

Do **not** unwrap/wrap manually or call any other deposit path.

---

## Withdraw

Always WETH out to the owner via `withdrawWeth(wethAmount)`.

| User prompt | `wethAmount` |
|-------------|--------------|
| "Withdraw X WETH / X ETH-notional from 0xSTRATEGY" | `X` in wei (`X * 1e18` if human) |
| "Withdraw Y% from 0xSTRATEGY" | `totalValueWeth() * Y / 100` |
| "Withdraw all / exit fully from 0xSTRATEGY" | `type(uint256).max` (`2^256-1`) |

Steps:

1. Confirm `owner() == user`.
2. Read `nav = totalValueWeth()`; if `0`, do not send a tx.
3. Cap computed amounts at `nav` (except use `max` for full exit).
4. `strategy.withdrawWeth(wethAmount)`.
5. Tell the user they receive **WETH**, not native ETH.

---

## Asset management

All token arguments are **ERC-20 asset addresses** (must already be on the UFloat router or the tx reverts).

| User prompt | Call |
|-------------|------|
| "Allow token 0xTOKEN on strategy 0xSTRATEGY" | `addAllowedToken(0xTOKEN)` |
| "Remove token 0xTOKEN …" | `removeAllowedToken(0xTOKEN)` |
| "Change asset to 0xTOKEN …" | `changeAsset(0xTOKEN)` |
| "Mint / remint position for 0xTOKEN …" | `mintPosition(0xTOKEN)` (same ASSET remints; other allowlisted token rotates; reverts if NAV ≤ stopLoss) |
| "Exit to stable / flatten to WETH …" | `exitToStable()` |

Before rotation, prefer showing current `ASSET()`, allowlist, `mode()`, and `totalValueWeth()`.

---

## Mint params (after deploy)

Deploy installs **defaults** only. When the user wants to tune (including right after deploy):

### `setMintParams`

```
setMintParams(
  targetAssetBps,
  rangeBelowTicks,
  rangeAboveTicks,
  stopLoss,
  feeReserveBps,
  reserveAddress
)
```

### `setOffensiveParams`

```
setOffensiveParams(
  minFloorTickCount,
  offensiveStaleDuration,
  offensiveAssetBps,
  minRangeBelowTicks
)
```

Optional: `setStratMethod(method)` — `0=ReBalanceOnly`, `1=OffensiveOnly`, `2=DefensiveOnly`, `3=OffensiveDefensive`.

**Rules**

- Bps: `10_000 = 100%`. Asset-target bps must be `1 … 9999`.
- Range tick params must be non-zero multiples of `tickSpacing` (usually `200`).
- `feeReserveBps` max `9000`; `reserveAddress` must be non-zero.
- Confirm all values with the user before sending.
- Read back current params first if the user says “update” without full numbers.

---

## Response rules

- After deploy, always show the new **strategy** address and initial **ASSET**.
- On manage writes, echo **strategy** + current **ASSET**.
- Format uint256 amounts as raw and human (÷ 1e18) when 18 decimals.
- Confirm large / ambiguous withdraw amounts before sending.
- Never invent a strategy address.
- If deploy/add/rotate reverts on router config, say the token is not configured on `UFloatSwapRouter` — do not guess another address.

## References

- Call/ABI details: `references/abi-and-calls.md`
- Strategy ABI (repo): `abis/UFloatStrategyV4.abi.json`
