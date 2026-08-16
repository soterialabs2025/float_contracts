# Deployed contract addresses

---

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

## Base — AutoVault V2 / V4

| Contract | Address |
|----------|---------|
| AutoOperatorRegistry | `0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8` |
| AutoFactory | `0x623222FCFA9Fb59F450a9991Ff644B0b76d32195` |
| AutoFactory (V2) | `0x79166c4E766830c1ba4e7893d633901068Cd0bD9` |
| AutoFactory (alt) | `0x0Fbca262D7CeBe0F5Df9fE6Eda4b8Ac9e84E7949` |
| AutoSwapRouter | `0x73fDB6Fc6C2F707cE93568998E94f8152909e7BC` |
| AutoKeeper | `0xf99D6314cc03137732a0D749eC4E97bc64d0b0d3` |
| AutoKeeper (alt) | `0xaFAF34176F18Eaec107A002cc36E3B6c369C9950` |

```text
["0x73fDB6Fc6C2F707cE93568998E94f8152909e7BC","0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8","0xf99D6314cc03137732a0D749eC4E97bc64d0b0d3"]
```

---

## Base — AutoVault Uniswap V3 (`contracts/auto-vaults-base-v3`)

RH `auto-vaults-rh-v3` twin on Base. ETH/WETH deposits, LiquidShares + ShareStaking, package ownership lock. Pools via `getPool(asset, WETH, poolFee)`.

| Contract | Address |
|----------|---------|
| AutoOperatorRegistry (reused) | `0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8` |
| AutoFactoryV3 | `0xc8f9126c289df82F5e3D1679Fba0BcB7F983fC87` |
| AutoSwapRouterV3 | `0x575f20F17b39220Bded0B3be4B6B42146645560a` |
| AutoKeeper | `0xF60Bb8318A95dCe44bA13B1d04Ffd9498e00f57d` |
| feeManager / SoteriaFeeManager (reused) | `0x9f6e579117BeAd116E25CfeC43e319637DE0bCEe` |

Uniswap V3 (Base): Factory `0x33128a8fC17869897dcE68Ed026d694621f6FDfD` · NPM `0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1` · SwapRouter02 `0x2626664c2603336E57B271c5C0b26F421741e481` · QuoterV2 `0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a` · WETH `0x4200000000000000000000000000000000000006`

Factory InfraConfig:

```text
["0x575f20F17b39220Bded0B3be4B6B42146645560a","0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8","0xF60Bb8318A95dCe44bA13B1d04Ffd9498e00f57d","0x9f6e579117BeAd116E25CfeC43e319637DE0bCEe"]
```

Deploy package: `deployVaultPackage(asset, poolFee)` — pool must exist via `factory.getPool(asset, WETH, poolFee)`.

---

## Base — Float Vault V4

| Contract | Address |
|----------|---------|
| FloatContractManagerV4 | `0xD12D64925340Ffc277d79b02A212Dd576701EaC9` |
| FloatStrategyV4 | `0xe8F7f6B5F687Ced014352c11BE198f9ED2322061` |
| FloatStrategyV4 (deployed) | `0x2c6cFaa300558565Fcd7Ddb1aC7e7219Eb5B7584` |
| FloatStrategyV4 (#2) | `0xb03AFFAE4F77bb967baa8965F45b03d6C6fab1BF` |
| FloatVaultV4 | `0x6bC0fEfBFE1E92608e40EBd5e9c68EbfE92D3AA1` |
| FloatSwapRouterV4 | `0xd58D5ed35A04718D7AEC582AC5d69d762bD7311A` |
| FloatLiquidTokenV4 | `0xdc8e384d3AA51D4344a12Ee263d18A4b5Df10B05` |
| FloatKeeperV4 | `0xC76520DC0B70b708D4c45F0c04d7dF9A07082983` |
| ASSET | `0xbf8e8f0e8866a7052f948c16508644347c57aba3` |
| AssetPoolV4 | `0x9196ada2ee67f89f347a59c2615057e3dcea28a7697020fd86f37e63f5c2d67a` |

Pool: fee `8388608` · hooks `0xbdf938149ac6a781f94faa0ed45e6a0e984c6544`

```text
["0x4200000000000000000000000000000000000006","0xbf8e8f0e8866a7052f948c16508644347c57aba3",8388608,200,"0xbb7784a4d481184283ed89619a3e3ed143e1adc0"]
```

Alt manager registry tuple:

```text
["FloatStrategyV4","FloatVaultV4","FloatSwapRouterV4","FloatLiquidTokenV4","FloatKeeperV4","ASSET","Demeter","Triton","WETH"]
["0x65E5af8382eB7816Ec80a98a8Ef2e7730C0CC183","0xdcc0B49CefA6Ed0e54A3C6aE0C37f3fdAeBaA9c9","0x0A66709Bef715c7ea08A45d597f0b230cD48079A","0x9eB486310Ed402c3249DCB8AE898ff48092558cd","0x8b54d03b776bD0e932836d8d7cBeBFfBcB9d30b1","0x572c4fa77623652411574c51b5ddb7e1b750aba3","0x208169b1321a09e614a68b06b7f600dc0e007212","0x5A86759516C094607544BF17Fde6Ed46c8e7771f","0x4200000000000000000000000000000000000006"]
```

---

## Base — Float Vault V3

| Contract | Address |
|----------|---------|
| FloatContractManager | `0x8b8a48Db78e6f1d1e465b3abaBea88f2532c7154` |
| FloatStrategy | `0xC534eE98365De10Cc508FACdd0e96b72Dc273399` |
| FloatStrategy (alt) | `0x541bd3e67858205aa406bA7c808b93aaCe2F0645` |
| FloatStrategy (alt) | `0x1695F22113571CA01076c1D76DcEB04145AE169B` |
| FloatStrategy (#1) | `0xf1f2447F6E78A7c69346EbC349d8D17cBf0980eA` |
| FloatVault | `0x1A9315979f839Cac000e0622cE21914fB518c023` |
| FloatVault (alt) | `0x7D77d93c76355b3d1CEE6b954b18cF40b7f3e90A` |
| FloatVault (alt) | `0x2C090e6fcA798DaD7c773Da9D1371ef5086f2337` |
| FloatSwapRouter | `0x01e97028262BE1Bc8e5E6EFAA2b6cC7cC3d94070` |
| FloatLiquidToken | `0xB26AEE244E88fF2cFAb5Fd2c989BD1357283a642` |
| FloatLiquidToken (alt) | `0xf2779B9B7F34bC46fB4bc2b860a6FCf0840BB41e` |
| FloatKeeper | `0x2Db9Cc1947593BF5056d12592989D3fc96C1fE4C` |
| ASSET | `0x1bc0c42215582d5a085795f4badbac3ff36d1bcb` |
| AssetPoolV3 | `0xc1a6fbedae68e1472dbb91fe29b51f7a0bd44f97` |

---

## Robinhood Chain (4663) — protocol

### Uniswap V4

| Contract | Address |
|----------|---------|
| WETH (aeWETH) | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| PositionManager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |
| PositionDescriptor | `0x9639443158E8C5efa35Bd45287bf2EFfd3D8dC06` |
| V4Quoter | `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94` |
| StateView | `0xF3334192D15450CdD385c8B70e03f9A6bD9E673b` |
| ReservesLens | `0x0000001b173C3bbF3984D417d8614E3eed34865B` |
| UniversalRouter | `0x8876789976dEcBfCbBbe364623C63652db8C0904` |
| ERC7914Detector | `0xc470458fc6A7E43471b31e6a2eB2612215A7102e` |

### Uniswap V3

| Contract | Address |
|----------|---------|
| UniswapV3Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| NonfungiblePositionManager | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| SwapRouter02 | `0xCaf681a66D020601342297493863E78C959E5cb2` |
| QuoterV2 | `0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7` |
| TickLens | `0x7DfD4F31be6814D2906BDE155c3e1B146EAc1468` |
| NFTDescriptor | `0x2E9D45Bb7b30549F5216813aDA9a6b7982C5B3ED` |
| NonfungibleTokenPositionDescriptor | `0x6F84dAE9c064ff453E5C8af51EfB819f8f610225` |
| UniswapInterfaceMulticall | `0x282A3C4D320Cc7f0d5eaf56B8029e4B88338f0a3` |

### UniswapX

| Contract | Address |
|----------|---------|
| DutchV3OrderReactor | `0x000000007A1C8e570011EeDF86A2A35593013cBA` |
| OrderQuoter | `0x00000000a3db63Df9078cBF3dF88B4CAdD5a7F58` |

### SushiSwap clAMM

Source: https://docs.sushi.com/contracts/clamm — separate pool universe from Uniswap RH V3.

| Contract | Address |
|----------|---------|
| Factory | `0xE51960f1B45f1C9FB6D166E6a884F866fC70433B` |
| Position Manager (NPM) | `0x51d0e5188afe12d502e29D982d20C190e7816107` |
| Tick Lens | `0x80126A8D806D029Ac551Ac6f30BAF06b785175d1` |
| Quoter | `0x3E290e5E01818002A0b672148BdC7514D861C7B3` |
| RedSnwapper (docs only; unused on remint) | `0x8E6fD69A77e88ee20Ba4B4fBd59DfCDA3EC0E98A` |
| Pool init code hash | `0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54` |
| aeWETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |

### Shared RH app tokens

| Name | Address |
|------|---------|
| feeManager / SoteriaFeeManagerRh | `0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| TRITON_RH_1 | `0xbED21b27411A80a557bBA5BDd4e31E05E09E09f4` |
| TRITON_RH_2 | `0xDaFb1B9789F4ECb75A006F65F99081802c871Ed4` |
| DEMETER_RH_1 | `0x3ec00017066Eb2e2348D82d0e21D5fDB3357CE16` |
| DEMETER_RH_2 | `0xa16c8cc08674F7c120A64d94f432377D427901a0` |

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

## Robinhood — AutoVault Uniswap V4 (`contracts/auto-vault-rh-v4`)

ETH-only deposits, LiquidShares + ShareStaking, package ownership lock. Manual ASSET/aeWETH `PoolKey` only (no native ETH `address(0)`).

| Contract | Address |
|----------|---------|
| AutoOperatorRegistry | `0x7df1120a04D82eA92EA2d5AA005e3316B37b936E` |
| AutoFactoryV2 (V4Rh) | `0x43799407FB4B32625DEE5c6b5F9f7Ea5A62fc685` |
| AutoSwapRouter | `0x5bD973F52Fb5c6a1f5C1D214FE9d1Cd58B8C2FbF` |
| AutoKeeper | `0xC05361895FaB7826137A0b8B3C6726A431f5aAe8` |
| feeManager | `0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE` |

InfraConfig `[swapRouter, operatorRegistry, keeper, feeManager]`:

```text
["0x5bD973F52Fb5c6a1f5C1D214FE9d1Cd58B8C2FbF","0x7df1120a04D82eA92EA2d5AA005e3316B37b936E","0xC05361895FaB7826137A0b8B3C6726A431f5aAe8","0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE"]
```

---

## Robinhood — AutoVault Uniswap V3 (`contracts/auto-vaults-rh-v3`)

| Contract | Address |
|----------|---------|
| AutoOperatorRegistry | `0x7df1120a04D82eA92EA2d5AA005e3316B37b936E` |
| AutoFactoryV3Rh | `0xeCad673d6B338D9b530401105332FFD55D35696F` |
| AutoFactoryV3Rh (alt) | `0x53a2430Eb649FdA4A8000a6Da3550EAB8E0D3882` |
| AutoSwapRouterV3Rh | `0xB76cdfF814220334Bb46C247F5D7f5d6bE7c8d3B` |
| AutoKeeperV3Rh | `0x6ef6afF9Dc71202252B9A0c95E1193aD7D1e5795` |
| feeManager | `0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE` |

### Example package — cash cat

| Field | Value |
|-------|-------|
| Asset | `0x020bfc650a365f8bb26819deaabf3e21291018b4` (fee `10000`) |
| strategy | `0xB8BF48DAc14aCEF0612CfdD9Ed1A1dba4F686dAd` |
| vault | `0xFd6f1F71F2aAe90f89c5b11bdfa03871e263F13A` |
| liquidToken | `0xe9E1618EB2806cd2d5a96E1f1d56FAbA2C13eC25` |
| poolFee | `10000` |
| active | `true` |

InfraConfig:

```text
["0xB76cdfF814220334Bb46C247F5D7f5d6bE7c8d3B","0x7df1120a04D82eA92EA2d5AA005e3316B37b936E","0x6ef6afF9Dc71202252B9A0c95E1193aD7D1e5795","0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE"]
```

Common V3 fee tiers: `100` · `500` · `3000` · `10000`. Pool must exist via `factory.getPool(asset, WETH, poolFee)`.

---

## Robinhood — AutoVault Sushi clAMM (`contracts/auto-vaults-rh-sushi-v3`)

| Contract | Address |
|----------|---------|
| AutoOperatorRegistry | `0xec59F9d472802C86dB25713033AeE0e306f4baDd` |
| AutoFactorySushiV3 | `0xbC69f10469FD4A99c0b403F2b72365a1f393a149` |
| AutoSwapRouterSushiV3 | `0xDe0723cee11909A044E05e637c22B6aa87d2584B` |
| AutoKeeper | `0xf99477aF260BAc25C47A5fe91E1CAB533D222872` |
| feeManager | `0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE` |

### Example package — sushicat

| Field | Value |
|-------|-------|
| Asset | `0x0ab8d01664d4bb625705f9f3c595a8a19b3dcfb0` (fee `10000`) |
| strategy | `0x3DB49a2Cd74AB11c050e579789CEa202050Ac791` |
| vault | `0x3cF68aEE1d23b24ecb7c9449CEdcB87d3AF55755` |
| liquidShares | `0xAc027Cfb55fBE18DB0E35D9Cf83792D52534f709` |
| shareStaking | `0xD243a81661754908e322dD66D90a60974822Ed0a` |

InfraConfig:

```text
["0xDe0723cee11909A044E05e637c22B6aa87d2584B","0xec59F9d472802C86dB25713033AeE0e306f4baDd","0xf99477aF260BAc25C47A5fe91E1CAB533D222872","0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE"]
```

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
