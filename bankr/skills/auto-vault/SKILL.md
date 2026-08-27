---
name: auto-vault
description: >-
  Query and transact Float Auto vaults by token/vault name alone (e.g. surplus,
  frong, cashcat, bnkr, suchicat) — name resolves chain + Uni/Sushi package +
  factory. Deposit ETH, claim/withdraw liquid shares, read NAV / fees / APR /
  liquid shares / staked balances, and link the Soteria vault page. Use when the
  user asks about named vaults, deposits, claims, APR, fees, or liquid shares
  without specifying chain or Uniswap version.
tags: [defi, vault, float, auto-vault, base, robinhood, uniswap-v3, uniswap-v4, sushiswap]
version: 2
visibility: private
metadata:
  clawdbot:
    emoji: "🏦"
    homepage: "https://docs.bankr.bot/skills/in-bankr/skill-format"
---

# Auto Vault (name → chain / package)

**Do not ask the user for chain or Uniswap/Sushi version.** A token/vault **name** (or ASSET address) is enough.

Named catalog + factories: `references/vault-names.md`.  
ABI / calls / APR HTTP: `references/abi-and-calls.md`.

Site host: **`https://www.soterialabs.io`**.

---

## Core resolution (name first)

1. Normalize the name: lowercase; strip trailing `vault` / `pool` / `token`.
2. If name is in **Deployed packages** in `vault-names.md` → use that row’s `asset`, `chainId`, `package`, `factory` (and cached clones if present).
3. Else if user gave `0xASSET` → scan factories (step 4).
4. Factory scan (when package not pinned): call `registry(asset)` on factories in order **Bv4 → Bv3 → RhV4 → RhV3 → Sv3**. First `vault != 0` wins; set package from that factory.
5. Decode registry: `(strategy, vault, liquidShares, shareStaking, … active)` — V3/Sushi also return `poolFee`.
6. Deposit / claim only when `vault != 0` and `active == true`.
7. Unknown name (not in Deployed packages) → say it isn’t in the catalog; do not guess.

Never invent names or addresses — only the catalog, on-chain registry, or user-supplied `0x`.

---

## Vault page link

After resolving `vault` + package:

| Package | Path |
|---------|------|
| Bv3 / Bv4 | `/dapp/auto-vaults-base/{vault}` |
| RhV3 / RhV4 | `/dapp/auto-vaults-rh/{vault}` |
| Sv3 | `/dapp/pool-dot-auto/{vault}` |

Full URL: `https://www.soterialabs.io` + path. For claim UX, append `?tab=claim`.

Always include this link in replies that resolve a vault.

---

## Listing / existence prompts

### "Is there a frong vault?" / "Does surplus have an auto vault?"

1. Resolve name → asset + package/factory (catalog or scan).
2. `(strategy, vault, liquidShares, shareStaking, active) = factory.registry(asset)`.
3. Reply yes/no with **name**, **package**, **chain**, **asset**, and if deployed: **vault**, **strategy**, **active**, **link**.

### "What vaults / tokens are available?"

List **Deployed packages** from `vault-names.md` (name + package + chain + link).

---

## Read prompts

Resolve vault via name / registry first. Prefer **LiquidShares** from registry (not vault ERC-20).

| User prompt | Call |
|-------------|------|
| "What is the pool value / NAV of surplus?" | `vault.balance()` → ETH-notional (18 decimals) |
| "What fees has frong earned?" | `strategy.UniswapFeesCollected()` (cumulative) |
| "What is the total liquid shares of bnkr?" | `liquidShares.totalSupply()` |
| "What are my liquid shares of cashcat?" | `liquidShares.balanceOf(user)` |
| "How much do I have staked?" | `shareStaking.stakedBalance(user)` if `shareStaking != 0` |
| "What is the APR of suchicat?" | See APR below |

`user` = connected / Bankr wallet.

### APR

1. Prefer the **site API** (same host as the dapp; no separate backend):  
   `GET https://www.soterialabs.io/api/vault-snapshots?vault={vault}&chain={base|robinhood}`  
   (`base` for Bv3/Bv4; `robinhood` for RhV3/RhV4/Sv3).  
   Body: `{ vault, chain, snapshots: [{ valueWeth, fees, ts }] }` — ETH floats + unix `ts`.  
   Compute ~7d realized fee APR from snapshots (see `abi-and-calls.md`).
2. If the API is unreachable or &lt; 2 points: report `UniswapFeesCollected` + `vault.balance()` and the **vault page link** (UI shows APR).

Do not invent an APR number without snapshots or an explicit fallback disclaimer.

---

## Deposit

**"Deposit 0.01 ETH into surplus"** / **"Deposit into frong"**

1. Resolve `vault` + package; require `active`.
2. Amount must be **ETH** for `depositETH`. If the user only says `$10` (USD), ask for an ETH amount (or convert if the agent already has a price — do not guess).
3. Use the correct **chain RPC** for the package (`8453` Base / `4663` Robinhood).
4. `vault.depositETH()` with `value = wei`.
5. Reply with tx hash; echo **name**, **package**, **chain**, **vault**, **asset**, **link**.

Do **not** use non-ETH deposit paths unless the user explicitly asks.

---

## Claim / withdraw

UI “claim” = withdraw liquid shares via the vault (not ShareStaking epoch claim).

`vault.withdraw(shares, asAsset)` — default `asAsset = false`.

| Package | Default out (`asAsset = false`) |
|---------|----------------------------------|
| Bv3 / Bv4 | WETH ERC-20 |
| RhV3 / Sv3 | aeWETH ERC-20 |
| RhV4 | **native ETH** |

| User prompt | Shares |
|-------------|--------|
| "Claim / withdraw x liquid shares from surplus" | `x` (× 1e18 if human 18-decimal) |
| "Withdraw x% from frong" | `liquidShares.balanceOf(user) * x / 100` |
| "Claim all / withdraw all from bnkr" | `liquidShares.balanceOf(user)` |

If `shares == 0`, do not send a tx. Cap at `balanceOf(user)`.

### ShareStaking epoch rewards

Only when the user asks for **staking / epoch rewards**: `shareStaking.claim(epoch)` (see `abi-and-calls.md`). Do not confuse with vault claim.

---

## Response rules

- Always show **name** (if any), **package**, **chain**, **ASSET**, **vault**, and **vault page link**.
- Format uint256 as raw + human (÷ 1e18) when 18 decimals.
- Confirm large/ambiguous amounts before sending.
- Keep `vault-names.md` updated when new packages deploy (especially vault/strategy/LS/SS clones).

## References

- Name / factory map: `references/vault-names.md`
- Call / ABI / APR: `references/abi-and-calls.md`
