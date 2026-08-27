# Auto Vault — names → chain / package

**Case-insensitive.** Strip trailing `vault` / `pool` / `token` before lookup.

Site: `https://www.soterialabs.io`

---

## Factories (authoritative)

| Package | Chain | chainId | DEX | Factory |
|---------|-------|---------|-----|---------|
| Bv3 | Base | 8453 | Uniswap V3 | `0x8E2D741F0EB545a6c3A51Adee243f89Afc2F040E` |
| Bv4 | Base | 8453 | Uniswap V4 | `0x2B1cf5F87651Ee8cAB851b4586023BA90133A812` |
| RhV3 | Robinhood | 4663 | Uniswap V3 | `0xB3E65742e90af23f30527A9745B63F90DAA48B78` |
| RhV4 | Robinhood | 4663 | Uniswap V4 | `0x3D19ecDb90B06626f8EC860F7aec9A378E760E8D` |
| Sv3 | Robinhood | 4663 | SushiSwap V3 | `0x0bb7e7A4a57ad938a253d2302604D1256067785A` |

Scan order when package is unknown: **Bv4 → Bv3 → RhV4 → RhV3 → Sv3**.

---

## Deployed packages (name → asset + package)

Name alone selects chain and factory. Always confirm clones with `factory.registry(asset)` before deposit/claim; refresh vault/strategy/LS/SS below when known.

| Name | ASSET | Package | Chain | Factory |
|------|-------|---------|-------|---------|
| `frong` | `0x6245e67affA44a23077f0Ea7f981a8DC743a0c47` | RhV4 | Robinhood (4663) | RhV4 factory |
| `cashcat` | `0x020bfC650A365f8BB26819deAAbF3E21291018b4` | RhV3 | Robinhood (4663) | RhV3 factory |
| `suchicat` | `0x0ab8d01664d4bB625705f9F3c595a8a19B3dCFb0` | Sv3 | Robinhood (4663) | Sv3 factory |
| `surplus` | `0xC52aeDec3374422d7510E294cfAa90799595CBa3` | Bv4 | Base (8453) | Bv4 factory |
| `bnkr` | `0x22aF33FE49fD1Fa80c7149773dDe5890D3c76F3b` | Bv3 | Base (8453) | Bv3 factory |

### Cached clones (from live `registry`)

Filled from factory `registry(asset)` — re-check before deposit/claim if redeployed.

| Name | Vault | Strategy | LiquidShares | ShareStaking |
|------|-------|----------|--------------|--------------|
| `frong` | `0x7863240F1d4988A57D9Af16f3A59B8CE8EbDaaA6` | `0x29802aA31A787dc1E643fBD90ED69445130f8327` | `0x76089956402aa54915866D89be06deBC6f6c2b6B` | `0xFa1Cd5e5f79e634354C2c902254f7a943D6D74e0` |
| `cashcat` | `0x724377bfde1c63a2A06E2F45E3b47d5D5640995c` | `0x98DA7a66cf08Ec07C260C86d45068aC4f650c5E7` | `0x8CcDE996822A1E78E0Eb9444984171F82c263096` | `0x82a783aA857aFEa73977F4FB9E3F6F986fD3B28B` |
| `suchicat` | `0x8D576Fe6Ac6fdD09a3ECaC61Fc35b9525B2a9dcE` | `0x8015020D5bCAdA745F369D6D1C9541031Cc14677` | `0xDEC2ead55FBBF234694F44b60A1CA65f8971F080` | `0x80732ef784ab656d413A64B2065eB3B2529622d1` |
| `surplus` | `0x4D815043E5515a729cde256685EB2dFCF76A6D2D` | `0xe43187EDf63760a8050691392f871675938E817F` | `0x6EbF67F761152e79287e84743E5035223c92c3dF` | `0xBE28754E8Eb7383d1B58B11EA13B4fA98da3056F` |
| `bnkr` | `0x2c2757C613aF5C084ae0EE0Af8a90736b5672d7f` | `0x0dD61Aa77Ec7AF521241B97Ae88EcAD61C9F56d4` | `0xA666AdEf7534adD874Cb95169ed0B64eb1Ee3290` | `0xfF009D8d9C1a9a1D617AAF4cDdfBc3C1b73244E3` |

### Vault page paths

| Package | Path |
|---------|------|
| Bv3 / Bv4 | `/dapp/auto-vaults-base/{vault}` |
| RhV3 / RhV4 | `/dapp/auto-vaults-rh/{vault}` |
| Sv3 | `/dapp/pool-dot-auto/{vault}` |

---

If a name is not in **Deployed packages** above, say it isn’t in the catalog — do not guess an address. For a raw `0xASSET`, scan factories’ `registry(asset)` (Bv4 → Bv3 → RhV4 → RhV3 → Sv3).
