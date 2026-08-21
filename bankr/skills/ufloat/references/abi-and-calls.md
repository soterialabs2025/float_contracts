# UFloat Strategy — ABI and call details

Chain: Base (`8453`).

| Contract | Address |
|----------|---------|
| UFloatStrategyFactoryV4 | `0xC6e260F7DCff98426c8652eED85315DB3965409A` |
| UFloatSwapRouter | `0x45cb7972Fb88127435d4791eAb034f07ED53064a` |
| WETH | `0x4200000000000000000000000000000000000006` |

Strategy clones: user-pasted or returned from `deployStrategy`.

---

## Deploy (factory)

```solidity
enum StratMethod { ReBalanceOnly, OffensiveOnly, DefensiveOnly, OffensiveDefensive } // 0..3

/// @notice Clones strategy; msg.sender becomes owner. tokens[0] = initial ASSET.
/// @dev Mint params are NOT passed — strategy boots with on-chain defaults.
function deployStrategy(
    uint8 stratMethod,
    address[] calldata tokens
) external returns (address strategy, uint256 keeperId);
```

### Deploy flow (pseudocode)

```
ask user for token addresses (not WETH)
tokens = [..]  # tokens[0] = initial ASSET
stratMethod = 0  # ReBalanceOnly unless user overrides

for t in tokens:
  require router.hasV4PoolConfig(t) == true

(strategy, keeperId) = factory.deployStrategy(stratMethod, tokens)
# save strategy address for later manage calls
```

### Router preflight

```solidity
function hasV4PoolConfig(address assetAddress) external view returns (bool);
```

---

## Strategy views

```solidity
function owner() external view returns (address);
function ASSET() external view returns (address);
function mode() external view returns (uint8); // 0 NORMAL, 1 DEFENSIVE, 2 OFFENSIVE, 3 STABLE
function totalValueWeth() external view returns (uint256);
function balanceOfIdle() external view returns (uint256);
function balanceOfPool() external view returns (uint256 assetAmt, uint256 wethAmt);
function poolValue() external view returns (uint256);
function getPositionId() external view returns (uint256);

function isAllowedToken(address token) external view returns (bool);
function allowedTokens(uint256 index) external view returns (address);
function allowedTokenCount() external view returns (uint256);

function stratMethod() external view returns (uint8);
function targetAssetBps() external view returns (uint256);
function rangeBelowTicks() external view returns (uint256);
function rangeAboveTicks() external view returns (uint256);
function stopLoss() external view returns (uint256);
function offensiveAssetBps() external view returns (uint256);
function minFloorTickCount() external view returns (uint256);
function offensiveStaleDuration() external view returns (uint256);
function minRangeBelowTicks() external view returns (uint256);
function feeReserveBps() external view returns (uint256);
function reserveAddress() external view returns (address);
function tickSpacing() external view returns (int24);
```

### Mode enum

| `mode()` | Name |
|----------|------|
| 0 | NORMAL |
| 1 | DEFENSIVE |
| 2 | OFFENSIVE |
| 3 | STABLE |

### StratMethod enum

| value | Name |
|-------|------|
| 0 | ReBalanceOnly |
| 1 | OffensiveOnly |
| 2 | DefensiveOnly |
| 3 | OffensiveDefensive |

---

## Owner writes — funding

```solidity
function depositETH() external payable;
function withdrawWeth(uint256 wethAmount) external; // use type(uint256).max for full exit
```

### Withdraw helpers

```
nav = totalValueWeth()
wethAmount = humanEth * 1e18          # amount
wethAmount = nav * pct / 100          # percent
wethAmount = 2^256 - 1                # all
```

---

## Owner writes — assets

```solidity
function addAllowedToken(address token) external;
function removeAllowedToken(address token) external;
function changeAsset(address newAsset) external;
function mintPosition(address token) external;
function exitToStable() external;
```

---

## Owner writes — params (after deploy)

Deploy does **not** take mint params. Tune on the strategy afterward:

```solidity
function setMintParams(
    uint256 targetAssetBps,
    uint256 rangeBelowTicks,
    uint256 rangeAboveTicks,
    uint256 stopLoss,
    uint256 feeReserveBps,
    address reserveAddress
) external;

function setOffensiveParams(
    uint256 minFloorTickCount,
    uint256 offensiveStaleDuration,
    uint256 offensiveAssetBps,
    uint256 minRangeBelowTicks
) external;

function setStratMethod(uint8 method) external;
```

- Asset-target bps: `1 … 9999` (`10_000 = 100%`).
- Range tick params: non-zero multiples of `tickSpacing` (default `200`).
- `feeReserveBps` ≤ `9000`; `reserveAddress != 0`.

---

## Semantics

| Concept | On-chain |
|---------|----------|
| Deploy | `factory.deployStrategy(method, tokens)` |
| Initial ASSET | `tokens[0]` |
| Strategy NAV | `totalValueWeth()` |
| Deposit | `depositETH{value}` (ETH in) |
| Withdraw | `withdrawWeth` (WETH out) |
| Full exit | `withdrawWeth(type(uint256).max)` |
| Tune bands | `setMintParams` / `setOffensiveParams` |

## Safety

- Preflight `hasV4PoolConfig` before deploy.
- Owner-only for deposit/withdraw/allowlist/mintPosition/param setters.
- Cap percent withdraws at `totalValueWeth()`; use `max` only for explicit full exit.
- Never invent strategy addresses.
