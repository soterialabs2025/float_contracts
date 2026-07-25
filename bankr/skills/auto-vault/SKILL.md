---
name: auto-vault
description: >-
  Query and transact Float Auto vaults on Base — list active ASSET pools from
  AutoFactory.registry, read pool Value / share supply / user shares from AutoVault,
  and deposit ETH or withdraw liquid-token shares. Use when the user asks about
  available/active Auto pools, pool value, liquid tokens/shares, or deposit/withdraw
  into an Auto vault for a given token (asset) address.
tags: [defi, vault, float, auto-vault, base, uniswap-v4]
version: 1
visibility: private
metadata:
  clawdbot:
    emoji: "🏦"
    homepage: "https://docs.bankr.bot/skills/in-bankr/skill-format"
---

# Auto Vault (Base)

Chain: **Base** (`8453`).

## Addresses (update if redeployed)

| Contract | Address |
|----------|---------|
| AutoFactory | `0xEa4F673955c4B016862A4889EAc68230C146CD39` |
| AutoOperatorRegistry | `0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8` |
| AutoSwapRouter | `0x73fDB6Fc6C2F707cE93568998E94f8152909e7BC` |
| AutoKeeper | `0xaFAF34176F18Eaec107A002cc36E3B6c369C9950` |
| WETH | `0x4200000000000000000000000000000000000006` |

Per-asset **vault** / **strategy** addresses are **not** fixed — resolve them from the factory (below). Example package (may be outdated): vault `0x5e2Ca26d8A65EEe02E1C3c0E8Fefe3aB0aB780A4`.

Always resolve live addresses via factory before writing txs. See `references/abi-and-calls.md` for ABI snippets.

## Core resolution

User prompts name a **token (ASSET)** address `0x…`. That is the Uniswap pair asset (not the liquid share token).

1. Call factory `registry(asset)` → `(strategy, vault, active)`.
2. If `strategy == address(0)` → pool not deployed; tell the user.
3. If `active == false` → deployed but inactive; do not deposit/withdraw unless user insists and understands risk.
4. All vault reads/writes go to the returned `vault` address.

```
registry(asset) → VaultRegistry { strategy, vault, active }
```

---

## AutoFactory prompts

### "What tokens pools are available?" / "What pools are active?"

**Goal:** list ASSET addresses with `registry[asset].active == true`.

1. `n = assetsLength()`
2. For `i = 0 .. n-1`: `asset = assets(i)`
3. `(strategy, vault, active) = registry(asset)`
4. Include `asset` in the reply only when `active == true` (and optionally show `vault` / `strategy`).

Also treat near-synonyms the same: “available pools”, “which auto vaults”, “list active tokens”.

---

## AutoVault prompts

Resolve `vault` from `registry(asset)` first. “Liquid tokens” / “shares” are the vault share balance (liquid token), exposed on the vault.

| User prompt | Call on `vault` |
|-------------|-----------------|
| "What is the pool value?" | `balance()` → WETH-notional Value (18 decimals) |
| "What is the total liquid tokens of 0xASSET?" | `totalSupply()` |
| "What is the total shares of 0xASSET?" | `totalSupply()` (same as liquid tokens) |
| "What is my total shares of 0xASSET?" | `balanceOf(user)` |
| "How many liquid tokens do I hold for 0xASSET?" | `balanceOf(user)` |

`user` = the connected wallet / Bankr agent wallet.

### Deposit

**"Deposit X amount of ETH into token pool 0xASSET"**

1. Resolve `vault` via `registry(asset)`; require `active == true`.
2. Convert `X` ETH → wei (`X * 1e18` if X is human ETH).
3. Send tx: `vault.depositETH()` with `value = wei`.
4. Reply with tx hash and shares minted if return data is available.

Do **not** use `depositWeth` / `depositAsset` unless the user explicitly says WETH or the ERC-20 asset.

### Withdraw

Withdraw burns **liquid-token shares** via `vault.withdraw(shares, asAsset)`.

- Default `asAsset = false` → user receives **WETH** (not native ETH).
- Use `asAsset = true` only if the user asks to receive the **ASSET** token.

| User prompt | Shares to withdraw |
|-------------|-------------------|
| "Withdraw x amount of liquid tokens from address 0xASSET" | `shares = x` (in raw share units; if user gives a human number and decimals are 18, multiply by `1e18`) |
| "Withdraw x% amount of liquid tokens from address 0xASSET" | `shares = balanceOf(user) * x / 100` |
| "Withdraw all liquid tokens from address 0xASSET" | `shares = balanceOf(user)` |

Then: `vault.withdraw(shares, false)` (or `true` if they want ASSET out).

If `shares == 0`, do not send a tx; tell the user they have no shares.

---

## Response rules

- Always show the **ASSET** address and resolved **vault** address.
- Format large uint256 values in both raw and human (÷ 1e18) when decimals are 18.
- On write txs, confirm asset, vault, amount/shares, and `asAsset` before sending when the amount is large or ambiguous.
- Never invent registry entries — only on-chain `assets` / `registry` results.

## References

- Call/ABI details: `references/abi-and-calls.md`
