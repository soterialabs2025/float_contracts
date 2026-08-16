# Robinhood Uniswap V4 PoolKeys

Chain **4663** | PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951` | aeWETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`

Collected by `scripts/find-rh-v4-poolkey.mjs`. Last update: **2026-08-15T23:50:54.046Z**.

Use with Float RH V4:
- UFloat: `setV4PoolConfig(asset, poolKey, hookData)`
- AutoVault: `deployVaultPackage(asset, poolKey, hookData)`
- Prefer ASSET/aeWETH keys; reject native ETH `address(0)`.

## Index (2)

| Token | Fee | Tick spacing | Hooks | PoolId | Block |
|-------|-----|--------------|-------|--------|-------|
| `0xe934e36A439C94017B64a3FecE66AF12099aBF50` | 10000 | 200 | `0x0` | `0x22a769cb...` | 14456666 |
| `0xe934e36A439C94017B64a3FecE66AF12099aBF50` | 8388608 | 160 | `0xFeDa24F0...` | `0xfbece126...` | 22458835 |

## `0x22a769cb04c0526e2f972f11c8cd1a5414a8e4a3ec678419356c46325ce8933e`

- **token (query):** `0xe934e36A439C94017B64a3FecE66AF12099aBF50`
- **pair filter:** `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- **tx:** `0xf849682c2bb44f6bd6539e2d9fb6fa56417b62c52018f48021fd52b43a0d2b8a`
- **block:** 14456666
- **tick:** 130404
- **hookData:** `0x`
- **first seen:** 2026-08-15T23:50:43.115Z
- **last seen:** 2026-08-15T23:50:54.046Z

```json
{
  "currency0": "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  "currency1": "0xe934e36A439C94017B64a3FecE66AF12099aBF50",
  "fee": 10000,
  "tickSpacing": 200,
  "hooks": "0x0000000000000000000000000000000000000000"
}
```

## `0xfbece126bde32e4116fd8e8b4bb3b7d80b2c5febf1fc7cc7025ed3b6fd413016`

- **token (query):** `0xe934e36A439C94017B64a3FecE66AF12099aBF50`
- **pair filter:** `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- **tx:** `0x4ef75de5e89bca9e8d07d1eea899408bb61b2d465eb4816e3d07f6477f995f33`
- **block:** 22458835
- **tick:** 122944
- **hookData:** `0x`
- **first seen:** 2026-08-15T23:50:43.115Z
- **last seen:** 2026-08-15T23:50:54.046Z

```json
{
  "currency0": "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  "currency1": "0xe934e36A439C94017B64a3FecE66AF12099aBF50",
  "fee": 8388608,
  "tickSpacing": 160,
  "hooks": "0xFeDa24F0d3805170E7566cE617CfBa01cE05D080"
}

["0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73", "0xe934e36A439C94017B64a3FecE66AF12099aBF50",]
["0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73","0xe934e36A439C94017B64a3FecE66AF12099aBF50",8388608,160,"0xFeDa24F0d3805170E7566cE617CfBa01cE05D080"]
```


