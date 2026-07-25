# Auto Vault — ABI and call details

## AutoFactory (`0xEa4F673955c4B016862A4889EAc68230C146CD39`)

```solidity
struct VaultRegistry {
    address strategy;
    address vault;
    bool active;
}

function registry(address asset) external view returns (address strategy, address vault, bool active);
function assets(uint256 index) external view returns (address);
function assetsLength() external view returns (uint256);
```

### List active pools (pseudocode)

```
n = assetsLength()
for i in 0..n-1:
  a = assets(i)
  (strategy, vault, active) = registry(a)
  if active: emit a, vault, strategy
```

## AutoVault (per-asset clone from `registry(asset).vault`)

```solidity
function balance() external view returns (uint256);           // pool NAV, WETH-notional
function totalSupply() external view returns (uint256);       // all liquid shares
function balanceOf(address account) external view returns (uint256); // user liquid shares

function depositETH() external payable returns (uint256 shares);

/// @param shares liquid-token amount to burn
/// @param asAsset true → ASSET out; false → WETH out
function withdraw(uint256 shares, bool asAsset) external returns (uint256 outAmount);

function asset() external view returns (address);
function strategy() external view returns (address);
function liquidToken() external view returns (address);
```

## Semantics

| Concept | On-chain |
|---------|----------|
| Token pool / ASSET | Key into `factory.registry(asset)` |
| Pool value | `vault.balance()` |
| Liquid tokens / shares (global) | `vault.totalSupply()` |
| My liquid tokens / shares | `vault.balanceOf(me)` |
| Deposit ETH | `vault.depositETH{value}` |
| Withdraw shares | `vault.withdraw(shares, asAsset)` |

Shares use **18 decimals** (AutoLiquidToken).

## Withdraw percent example

User: “Withdraw 25% … from 0xASSET”

```
bal = vault.balanceOf(me)
shares = bal * 25 / 100
vault.withdraw(shares, false)
```

## Safety

- Skip inactive registry rows for deposits.
- Cap withdraw `shares` at `balanceOf(me)`.
- Native ETH out is not supported; WETH out is the default.
