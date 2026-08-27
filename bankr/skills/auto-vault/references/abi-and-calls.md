# Auto Vault — ABI and call details

Resolve **name → package → factory → registry(asset)** first (`vault-names.md`). Use the package’s **chainId** for all RPC calls.

---

## Chains / wrapped ETH

| Chain | chainId | Native | Wrapped ETH |
|-------|---------|--------|-------------|
| Base | 8453 | ETH | WETH `0x4200000000000000000000000000000000000006` |
| Robinhood | 4663 | ETH | aeWETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |

RhV4 withdraw (`asAsset=false`) pays **native ETH**, not aeWETH.

---

## AutoFactory — `registry(asset)`

### V4 (Bv4, RhV4)

```solidity
function registry(address asset) external view returns (
    address strategy,
    address vault,
    address liquidShares,
    address shareStaking,
    bool active
);
function assets(uint256 index) external view returns (address);
function assetsLength() external view returns (uint256);
```

### V3 / Sushi (Bv3, RhV3, Sv3)

```solidity
function registry(address asset) external view returns (
    address strategy,
    address vault,
    address liquidShares,
    address shareStaking,
    uint24 poolFee,
    bool active
);
function assets(uint256 index) external view returns (address);
function assetsLength() external view returns (uint256);
```

`vault == address(0)` → not deployed on that factory.

### Multi-factory scan (unknown package)

Call `registry(asset)` on Bv4 → Bv3 → RhV4 → RhV3 → Sv3. First non-zero `vault` wins.

---

## AutoVault (clone from `registry.vault`)

```solidity
function balance() external view returns (uint256); // NAV, ETH-notional (18 decimals)
function depositETH() external payable returns (uint256 shares);
function withdraw(uint256 shares, bool asAsset) external returns (uint256 outAmount);
function asset() external view returns (address);
function strategy() external view returns (address);
function liquidShares() external view returns (address); // if exposed; else use registry
function shareStaking() external view returns (address);
```

Do **not** use `vault.totalSupply` / `vault.balanceOf` — shares live on **LiquidShares**.

### Withdraw out token (`asAsset = false`)

| Package | Out |
|---------|-----|
| Bv3 / Bv4 | WETH |
| RhV3 / Sv3 | aeWETH |
| RhV4 | native ETH |

`asAsset = true` → ASSET ERC-20 out.

---

## LiquidShares (clone from `registry.liquidShares`)

```solidity
function totalSupply() external view returns (uint256);
function balanceOf(address account) external view returns (uint256);
```

Shares: **18 decimals**.

---

## Strategy (clone from `registry.strategy`)

```solidity
function UniswapFeesCollected() external view returns (uint256); // cumulative fee notional
function poolValue() external view returns (uint256);           // if needed; prefer vault.balance()
```

“Fees earned” → `UniswapFeesCollected()` (cumulative lifetime, not trailing window).

---

## ShareStaking (clone from `registry.shareStaking`)

```solidity
function stakedBalance(address user) external view returns (uint256);
function claim(uint256 epoch) external returns (uint256 wethOut);
function currentEpoch() external view returns (uint256);
function notifyReward(address token, uint256 amount) external; // strategy-only
```

Use `claim(epoch)` only when the user asks for **staking / epoch rewards**.  
UI “claim shares” = `vault.withdraw`, not this.

---

## Deposit / withdraw examples

Deposit 0.01 ETH:

```
vault.depositETH{value: 0.01e18}()
```

Withdraw 25% of liquid shares (default out):

```
bal = liquidShares.balanceOf(me)
shares = bal * 25 / 100
vault.withdraw(shares, false)
```

---

## APR (dapp snapshots + fallback)

Site: `https://www.soterialabs.io`

```
GET /api/vault-snapshots?vault={vaultAddress}&chain={base|robinhood}
```

- `chain=base` for Bv3 / Bv4  
- `chain=robinhood` for RhV3 / RhV4 / Sv3  

Response includes snapshot points with pool value, cumulative fees, and timestamps (wei / unix). Compute ~**7-day realized fee APR** like the dapp:

1. Sort points by `ts`.
2. Take trailing window (~7 days from latest).
3. For each consecutive pair, fee delta / capital during interval; sum interval returns; annualize by `SECONDS_PER_YEAR / elapsed`.
4. Report one decimal percent (e.g. `12.3`). If &lt; 2 points → no APR.

**Fallback** if HTTP fails: report `UniswapFeesCollected` + `vault.balance()` and the vault page URL (UI shows APR). Do not fabricate a rate.

### Vault page URLs

```
https://www.soterialabs.io/dapp/auto-vaults-base/{vault}     # Bv3, Bv4
https://www.soterialabs.io/dapp/auto-vaults-rh/{vault}       # RhV3, RhV4
https://www.soterialabs.io/dapp/pool-dot-auto/{vault}        # Sv3
```

Claim tab: append `?tab=claim`.

---

## Semantics cheat sheet

| Concept | On-chain / HTTP |
|---------|-----------------|
| Name → package / chain | `vault-names.md` Deployed packages |
| Token ASSET → clones | `factory.registry(asset)` |
| Pool NAV | `vault.balance()` |
| Fees earned (cumulative) | `strategy.UniswapFeesCollected()` |
| Liquid shares (global) | `liquidShares.totalSupply()` |
| My liquid shares | `liquidShares.balanceOf(me)` |
| My staked shares | `shareStaking.stakedBalance(me)` |
| APR | `/api/vault-snapshots` then 7d fee APR |
| Deposit ETH | `vault.depositETH{value}` |
| Claim / withdraw shares | `vault.withdraw(shares, asAsset)` |
| Epoch staking reward | `shareStaking.claim(epoch)` |

---

## Safety

- Skip inactive registry rows for deposits / claims.
- Cap withdraw `shares` at `liquidShares.balanceOf(me)`.
- Use the correct chain RPC for the resolved package.
- Confirm large or ambiguous amounts before sending txs.
