---
name: auto-vault
description: >-
  Query and transact Float Auto vaults on Base by token/vault name (e.g. surplus,
  nook, molten) or ASSET address — check if a named vault exists via factory
  registry, deposit ETH, withdraw liquid-token shares, read pool value / shares.
  Use when the user asks “is there an X vault?”, named deposits, available
  pools, or liquid tokens/shares.
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
| AutoFactory | `0x0Fbca262D7CeBe0F5Df9fE6Eda4b8Ac9e84E7949` |
| AutoOperatorRegistry | `0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8` |
| AutoSwapRouter | `0x73fDB6Fc6C2F707cE93568998E94f8152909e7BC` |
| AutoKeeper | `0xf99D6314cc03137732a0D749eC4E97bc64d0b0d3` |
| WETH | `0x4200000000000000000000000000000000000006` |

Named vaults (fast path): `references/vault-names.md`.  
ABI details: `references/abi-and-calls.md`.

## Core resolution (name first)

Users often say a **vault/token name** (“surplus vault”, “molten”), not `0x…`.

1. Normalize the name (lowercase; strip trailing “vault” / “pool” / “token”).
2. If name is in **Deployed packages** in `vault-names.md` → use that `vault` / `asset` / `strategy`.
3. Else if name is in **Known tokens** → take `asset`, then `factory.registry(asset)`.
4. Else if user gave `0xASSET` → `factory.registry(asset)`.
5. If still unknown, say the name isn’t in the catalog; optionally scan factory `assets`.
6. Deposit/withdraw only when `vault != 0` and preferably `active == true`.

Never invent names or addresses — only the reference tables or on-chain registry.

---

## AutoFactory / listing prompts

### "Is there a molten vault?" / "Does SAIRI have an auto vault?"

1. Look up name → **ASSET** in Known tokens (`vault-names.md`).
2. If not in catalog → say unknown token name (don’t guess an address).
3. `(strategy, vault, active) = factory.registry(asset)`.
4. Reply yes/no with `asset`, and if deployed: `vault`, `strategy`, `active`.

### "What vaults / tokens are available?"

1. List **Deployed packages** (name + vault) from `vault-names.md`.
2. Optionally note Known tokens can be checked via registry; or scan factory `assetsLength`.

---

## AutoVault prompts

Resolve vault via **name** or `registry(asset)` first.

| User prompt | Call on `vault` |
|-------------|-----------------|
| "What is the pool value of surplus?" | `balance()` → WETH-notional (18 decimals) |
| "What is the total liquid tokens / shares of nook?" | `totalSupply()` |
| "What is my shares of surplus?" | `balanceOf(user)` |

`user` = connected / Bankr wallet.

### Deposit

**"Deposit 0.01 ETH into surplus vault"** / **"Deposit into nook"**

1. Resolve `vault` (name table or registry); require active when checked on-chain.
2. Amount must be **ETH** for `depositETH`. If the user only says `$10` (USD), ask for an ETH amount (or convert if the agent already has a price — do not guess).
3. `vault.depositETH()` with `value = wei`.
4. Reply with tx hash; echo **name**, **vault**, **asset**.

Do **not** use `depositWeth` / `depositAsset` unless the user explicitly says WETH or the ERC-20 asset.

### Withdraw

`vault.withdraw(shares, asAsset)` — default `asAsset = false` → **WETH** out.

| User prompt | Shares |
|-------------|--------|
| "Withdraw x liquid tokens from surplus" | `x` (× 1e18 if human 18-decimal) |
| "Withdraw x% from nook" | `balanceOf(user) * x / 100` |
| "Withdraw all from surplus" | `balanceOf(user)` |

If `shares == 0`, do not send a tx.

---

## Response rules

- Always show **name** (if any), **ASSET**, and **vault**.
- Format uint256 as raw + human (÷ 1e18) when 18 decimals.
- Confirm large/ambiguous amounts before sending.
- Keep `vault-names.md` updated when new packages deploy.

## References

- Name map: `references/vault-names.md`
- Call/ABI: `references/abi-and-calls.md`
