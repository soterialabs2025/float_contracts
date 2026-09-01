# Current AutoVault infra addresses

Fresh infra deploys (router + keeper + factory). Shared per-chain `AutoOperatorRegistry` + feeManager reused from prior deploys. No sample vault packages in this pass.


## Shared — Base (8453)

| Name | Address |
|------|---------|
| Owner | `0xc9ea49257ab99b4b8648df0641f15aec038c57e8` |
| Demeter | `0x208169b1321a09e614a68b06b7f600dc0e007212` |
| Triton | `0x66d60E991D09447245d668671d079b57eB48f58E` |
| Demeter_Two | `0xa5eF8cEFEc50D33C3413ecE773CEe05aA0c8e1cB` |
| Triton_Two | `0x1CfA9B75FbA20A638b7ED10074c28087B2507f39` |
| SoteriaFeeManager | `0x9f6e579117BeAd116E25CfeC43e319637DE0bCEe` |
| WETH | `0x4200000000000000000000000000000000000006` |
| Uniswap V4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| Uniswap V4 PositionManager | `0x7C5f5A4bBd8fD63184577525326123B519429bDc` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |


## Base (8453) — AutoVault Bv3

| Contract | Address |
|---|---|
| AutoSwapRouterBv3 | `0x07758574b154dF860748748365C35B15d869Cb2d` |
| AutoKeeperBv3 | `0xdd66727dB1D19345d3f5468e4A7a9073F28b591B` | 
| AutoFactoryBv3 | `0x8E2D741F0EB545a6c3A51Adee243f89Afc2F040E` | block:`50353974` |
| AutoOperatorRegistry (shared) | `0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8` |
| feeManager (shared) | `0x9f6e579117BeAd116E25CfeC43e319637DE0bCEe` |
| Deployer | `0xC9EA49257ab99B4B8648DF0641F15aec038c57E8` |
| AutoVaultBv3 | `0x2c2757C613aF5C084ae0EE0Af8a90736b5672d7f` |
| AutoStrategyBv3 | `0x0dD61Aa77Ec7AF521241B97Ae88EcAD61C9F56d4` |
| LiquidSharesBv3 | `0xA666AdEf7534adD874Cb95169ed0B64eb1Ee3290` |
| ShareStakingBv3 | `0xfF009D8d9C1a9a1D617AAF4cDdfBc3C1b73244E3` |

**InfraConfig** `[swapRouter, operatorRegistry, keeper, feeManager]`:
**Asset**:`0x22af33fe49fd1fa80c7149773dde5890d3c76f3b` - `10000`
**Asset**:`0x1bc0c42215582d5a085795f4badbac3ff36d1bcb` - `10000`
```text
["0x07758574b154dF860748748365C35B15d869Cb2d","0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8","0xdd66727dB1D19345d3f5468e4A7a9073F28b591B","0x9f6e579117BeAd116E25CfeC43e319637DE0bCEe"]


## Base (8453) — AutoVault Bv3 - TEST

| Contract | Address |
|---|---|
| AutoSwapRouterBv3 | `0x079E2D7947a5e4cF05B985144A7E87a152327c24` |
| AutoKeeperBv3 | `0x3a3cD7Ae823fc2050385843D2Bd8E146c9A20380` | 
| AutoFactoryBv3 | `0x2F8fff8436a0b56C7b4b4346C9b2E86e38333FE1` | block:`50726300` |
| LiquidityLibraryV2 (shared) | `0x91a83368242726efDc8BB1a85EB9ff9765B7B81C` |
| AutoOperatorRegistry (shared) | `0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8` |
| feeManager (shared) | `0x9f6e579117BeAd116E25CfeC43e319637DE0bCEe` |
| Deployer | `0xC9EA49257ab99B4B8648DF0641F15aec038c57E8` |
| AutoVaultBv3 | `0x704a06fF9d1cc3A9451ed6396a9B19490fD6BF67` |
| AutoStrategyBv3 | `0x006290903eb88AfD793Bf54304a3f72282820B6B` |
| LiquidSharesBv3 | `0xc1c46147CCA385099986e9e4EDef9c7dD177D41C` |
| ShareStakingBv3 | `0x71581a6cF826E69cF9Fbd9DF624D0a799DB5b1E8` |
```

["0x079E2D7947a5e4cF05B985144A7E87a152327c24","0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8","0x3a3cD7Ae823fc2050385843D2Bd8E146c9A20380","0x9f6e579117BeAd116E25CfeC43e319637DE0bCEe"]



## Base (8453) — AutoVault Bv4

| Contract | Address |
|---|---|
| AutoSwapRouterBv4 | `0xC64843B634839efc3C1AD3D32FCCb02F4eFC9f5e` |
| AutoKeeperBv4 | `0x68f9fD0c4Ad3B8079d27396510d9f183125ba5f3` |
| AutoFactoryBv4 | `0x2B1cf5F87651Ee8cAB851b4586023BA90133A812` | block:`50332556` |
| AutoVaultBv4 | `0x4D815043E5515a729cde256685EB2dFCF76A6D2D` |
| AutoStrategyBv4 | `0x9531673cf88341fC03f31a5c9a60D56d5c01A718` |
| LiquidSharesBv4 | `0x6EbF67F761152e79287e84743E5035223c92c3dF` |
| ShareStakingBv4 | `0xBE28754E8Eb7383d1B58B11EA13B4fA98da3056F` |
| AutoOperatorRegistry (shared) | `0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8` |
| feeManager (shared) | `0x9f6e579117BeAd116E25CfeC43e319637DE0bCEe` |
| Deployer | `0xC9EA49257ab99B4B8648DF0641F15aec038c57E8` |

**InfraConfig** `[swapRouter, operatorRegistry, keeper, feeManager]`:
**Asset Tuple**:`0xc52aedec3374422d7510e294cfaa90799595cba3 = ["0x4200000000000000000000000000000000000006","0xc52aedec3374422d7510e294cfaa90799595cba3",8388608,200,"0xbb7784a4d481184283ed89619a3e3ed143e1adc0"]`


```text
["0xC64843B634839efc3C1AD3D32FCCb02F4eFC9f5e","0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8","0x68f9fD0c4Ad3B8079d27396510d9f183125ba5f3","0x9f6e579117BeAd116E25CfeC43e319637DE0bCEe"]
```

## RH (4663) — AutoVault RhV3

| Contract | Address |
|---|---|
| AutoSwapRouterRhV3 | `0x8A8c18445792e04e8512D5c6CD680331F9575a3F` |
| AutoKeeperRhV3 | `0xD35CE6610AcB37D545bb5ec4192fC50505Dd26Ad` |
| AutoFactoryRhV3 | `0x14b5cC10196f0dd84C76E60FEDed2101f294b095` |
| AutoOperatorRegistry (shared) | `0x7df1120a04D82eA92EA2d5AA005e3316B37b936E` |
| feeManager (shared) | `0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE` |
| Deployer | `0xf99faA74aF8cb06479bFCb62495F0404089EDc83` |
| AutoVaultRhv3 | `0x98877EFE1397673824CD9cC3b24190174380c4C4` |
| AutoStrategyRhv3 | `0x20Fb1380b78bc7F92eD37d40f2e891F9FA035C61` |
| LiquidSharesRhv3 | `0xdC89087e00e1c7876B144c912E611a54A131F631` |
| ShareStakingRhv3 | `0x387FFE006265e09ED68De71D009A0e6b3Cb051D7` |

**InfraConfig**: `[swapRouter, operatorRegistry, keeper, feeManager]`
**Asset**:`0x020bfc650a365f8bb26819deaabf3e21291018b4` - `10000`

```text
["0x8A8c18445792e04e8512D5c6CD680331F9575a3F","0x7df1120a04D82eA92EA2d5AA005e3316B37b936E","0xD35CE6610AcB37D545bb5ec4192fC50505Dd26Ad","0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE"]


```

## RH (4663) — AutoVault RhV4

| Contract | Address |
|---|---|
 AutoSwapRouterRhV4 | `0x493CDA10F61fb2ad2AC7149EfBBA2114Dd460D05` |
| AutoKeeperRhV4 | `0x79F9ea39E7e5304791DF8cfEe835F6592c35e022` |
| AutoFactoryRhV4 | `0x3D19ecDb90B06626f8EC860F7aec9A378E760E8D` |
| AutoOperatorRegistry (shared) | `0x7df1120a04D82eA92EA2d5AA005e3316B37b936E` |
| feeManager (shared) | `0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE` |
| Deployer | `0xf99faA74aF8cb06479bFCb62495F0404089EDc83` |
| AutoVaultRhv4 | `0x7863240F1d4988A57D9Af16f3A59B8CE8EbDaaA6` |
| AutoStrategyRhv4 | `0x29802aA31A787dc1E643fBD90ED69445130f8327` |
| LiquidSharesRhv4 | `0x76089956402aa54915866D89be06deBC6f6c2b6B` |
| ShareStakingRhv4 | `0xFa1Cd5e5f79e634354C2c902254f7a943D6D74e0` |


 

**Asset**:`0x6245e67affA44a23077f0Ea7f981a8DC743a0c47`:["0x0000000000000000000000000000000000000000","0x6245e67affA44a23077f0Ea7f981a8DC743a0c47",2500,60,"0x0000000000000000000000000000000000000000"] -

["960","960","780","780"]

```text
["0x493CDA10F61fb2ad2AC7149EfBBA2114Dd460D05","0x7df1120a04D82eA92EA2d5AA005e3316B37b936E","0x79F9ea39E7e5304791DF8cfEe835F6592c35e022","0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE"]

```

## RH (4663) — AutoVault Sv3 (Sushi)

| Contract | Address |
|---|---|
| AutoSwapRouterSv3 | `0x568dCA271e5F7edb9769f5eA6076e2DA8D4014e8` |
| AutoKeeperSv3 | `0x3Cb0A8c25356BF5764C4510A79458e73a6639372` |
| AutoFactorySv3 | `0x0bb7e7A4a57ad938a253d2302604D1256067785A` |
| AutoOperatorRegistry (shared) | `0x7df1120a04D82eA92EA2d5AA005e3316B37b936E` |
| feeManager (shared) | `0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE` |
| Deployer | `0xf99faA74aF8cb06479bFCb62495F0404089EDc83` |
| AutoVaultRhv3 | `0x8D576Fe6Ac6fdD09a3ECaC61Fc35b9525B2a9dcE` |
| AutoStrategyRhv3 | `0x8015020D5bCAdA745F369D6D1C9541031Cc14677` |
| LiquidSharesRhv3 | `0xDEC2ead55FBBF234694F44b60A1CA65f8971F080` |
| ShareStakingRhv3 | `0x80732ef784ab656d413A64B2065eB3B2529622d1` |
**InfraConfig**: `[swapRouter, operatorRegistry, keeper, feeManager]`

**Asset**:`0x0ab8d01664d4bb625705f9f3c595a8a19b3dcfb0` - `10000`

```text
["0x568dCA271e5F7edb9769f5eA6076e2DA8D4014e8","0x7df1120a04D82eA92EA2d5AA005e3316B37b936E","0x3Cb0A8c25356BF5764C4510A79458e73a6639372","0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE"]
```

## Robinhood — AutoVault Sushi clAMM 

Swaps: Quoter + direct `pool.swap` (no SwapRouter02 / RedSnwapper on remint path).

---

## Deploy notes (RH AutoVault)

1. `AutoOperatorRegistry`
2. Swap router → `setStrategyFactory`
3. `AutoKeeper(registry)` → `setStrategyFactory`
4. Factory with `{swapRouter, operatorRegistry, keeper, feeManager}`
5. `deployVaultPackage` (V4: ASSET/aeWETH PoolKey + hookData; V3/Sushi: asset + poolFee) — authorizes strategy and ShareStaking
6. Optional: `transferPackageOwnership(asset, tba)`

Use aeWETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` on Robinhood (not Base `0x4200…`, not native ETH `address(0)` in V4 keys).


---

## Robinhood — UFloat V3 (`contracts/ustrategy-rh-v3`)

Owner-funded Uni V3 twin of Base `ustrategy-v3`. Pools via `getPool(asset, aeWETH, fee)` (no PoolKey). Reuses RH AutoOperatorRegistry + SoteriaFeeManagerRh above. Not AutoVault (no LiquidShares / ShareStaking).

| Contract | Address |
|----------|---------|
| UFloatSwapRouterV3 | `0x932f208D180dB8e375E17f88e86A9C1a81d7ACa8` |
| UFloatKeeperV3 | `0xe2E744063446E372B9E28e4BB38aaBFcc6D43eE8` |
| UFloatStrategyFactoryV3 | `0xA8966d59f38e7bE263C533Ccda87F36eaf5FFefE` |
| LiquidityLibraryV2 (linked) | `0x381BeC992900215b9752Da4CD5985B04fb6c5D6b` |

Reused: AutoOperatorRegistry `0x7df1120a04D82eA92EA2d5AA005e3316B37b936E` · feeManager `0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE`

Uniswap V3 (RH): Factory / NPM / SwapRouter02 / QuoterV2 — see protocol table above. WETH = aeWETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`.

Factory InfraConfig:

```text
["0x932f208D180dB8e375E17f88e86A9C1a81d7ACa8","0x7df1120a04D82eA92EA2d5AA005e3316B37b936E","0xe2E744063446E372B9E28e4BB38aaBFcc6D43eE8","0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE"]
```

Deploy note: Demeter/Triton RH had no Uni V3 pools at 500/3000/10000 at seed time — call `setPoolConfig(asset, fee)` before `deployStrategy`.

---


---

## Robinhood — UFloat V4 (`contracts/ustrategy-rh-v4`)

Owner-funded Uni V4 twin of Base `ustrategy`. Manual ASSET/aeWETH `PoolKey` via `setV4PoolConfig` (no constructor Clanker seeds; native ETH `address(0)` rejected). Reuses RH AutoOperatorRegistry + SoteriaFeeManagerRh. Not AutoVault.

| Contract | Address |
|----------|---------|
| UFloatSwapRouter | `0x562cfd3C373A649932597AD5D7a7c1CEa8402A76` |
| UFloatKeeper | `0x2cF7c9aB33a8248B07435d58cc7754eB1EaB8d12` |
| UFloatStrategyFactoryV4 | `0xBDE2231aC15DdbACa7A24837875e6F7DF0a855D9` |

Reused: AutoOperatorRegistry `0x7df1120a04D82eA92EA2d5AA005e3316B37b936E` · feeManager `0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE`

Uniswap V4 (RH): PoolManager / PositionManager / Quoter / Permit2 — see protocol table above. WETH = aeWETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`.

Factory InfraConfig:

```text
["0x562cfd3C373A649932597AD5D7a7c1CEa8402A76","0x7df1120a04D82eA92EA2d5AA005e3316B37b936E","0x2cF7c9aB33a8248B07435d58cc7754eB1EaB8d12","0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE"]
```

Deploy note: call `setV4PoolConfig(asset, PoolKey, hookData)` before `deployStrategy`.

---


---

## Base — UFloat V4 (`contracts/ustrategy`)

| Contract | Address |
|----------|---------|
| OperatorRegistry | `0x704618C4E8C201F45536DFD583911F8335e853Dd` |
| UFloatStrategyFactoryV4 | `0xC6e260F7DCff98426c8652eED85315DB3965409A` |
| UFloatSwapRouter | `0x45cb7972Fb88127435d4791eAb034f07ED53064a` |
| FloatContractManagerV4 | `0xD12D64925340Ffc277d79b02A212Dd576701EaC9` |
| UFloatKeeperV4 | `0x211035197D91C7a8b4D791449051D5163e5d5855` |
| UFloatKeeperV4 (alt) | `0x7641E1F6EE149A88C710E453Aa65616F5F90D1a0` |

Factory InfraConfig `[swapRouter, operatorRegistry, keeper, feeManager]`:

```text
["0x45cb7972Fb88127435d4791eAb034f07ED53064a","0x704618C4E8C201F45536DFD583911F8335e853Dd","0x211035197D91C7a8b4D791449051D5163e5d5855","0x9f6e579117BeAd116E25CfeC43e319637DE0bCEe"]
```

---

## Base — UFloat V3 (`contracts/ustrategy-v3`)

Owner-funded Uni V3 twin of UFloat V4. Pools via `getPool(asset, WETH, fee)` (no PoolKey). Reuses OperatorRegistry + SoteriaFeeManager above.

| Contract | Address |
|----------|---------|
| UFloatSwapRouterV3 | `0x052Fc86811Ec67E5af3DcA37d398aC72832E5A13` |
| UFloatKeeperV3 | `0x3eB9aa6eB9d70485918eD87cE0ed1263d0bD6f24` |
| UFloatStrategyFactoryV3 | `0x40a338E05cccD484bbA1a8da6a98fff0E302f12f` |

Uniswap V3 (Base): Factory `0x33128a8fC17869897dcE68Ed026d694621f6FDfD` · NPM `0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1` · SwapRouter02 `0x2626664c2603336E57B271c5C0b26F421741e481` · QuoterV2 `0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a`

Factory InfraConfig:

```text
["0x052Fc86811Ec67E5af3DcA37d398aC72832E5A13","0x704618C4E8C201F45536DFD583911F8335e853Dd","0x3eB9aa6eB9d70485918eD87cE0ed1263d0bD6f24","0x9f6e579117BeAd116E25CfeC43e319637DE0bCEe"]
```

---
