# Robinhood Uniswap V4 PoolKeys

Chain **4663** | PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951` | aeWETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`

Collected by `scripts/find-rh-v4-poolkey.mjs`. Last update: **2026-08-18T04:07:55.413Z**.

Use with Float RH V4:
- UFloat: `setV4PoolConfig(asset, poolKey, hookData)`
- AutoVault: `deployVaultPackage(asset, poolKey, hookData, BandConfig)` — native ETH pairs (`currency0 = address(0)`, `currency1 = asset`). Band widths must be positive multiples of `tickSpacing`.
- Prefer ASSET/aeWETH keys; reject native ETH `address(0)`.

## Index (15)

| Token | Fee | Tick spacing | Hooks | PoolId | Block |
|-------|-----|--------------|-------|--------|-------|
| `0x45242320DBB855EeA8Fd36804C6487E10E97FCF9` | 8388608 | 100 | `0xFeDa24F0...` | `0xdbaf32b8...` | 12251536 |
| `0x45242320DBB855EeA8Fd36804C6487E10E97FCF9` | 8388608 | 60 | `0x96CE193F...` | `0x781f4bd6...` | 12455648 |
| `0xe934e36A439C94017B64a3FecE66AF12099aBF50` | 10000 | 200 | `0x0` | `0xd33c8fd3...` | 12670814 |
| `0xe934e36A439C94017B64a3FecE66AF12099aBF50` | 985000 | 19700 | `0x0` | `0x678cd61c...` | 12673199 |
| `0xe934e36A439C94017B64a3FecE66AF12099aBF50` | 850000 | 17000 | `0x0` | `0x7aadc9bf...` | 12675794 |
| `0x45242320DBB855EeA8Fd36804C6487E10E97FCF9` | 25400 | 508 | `0x0` | `0xca8e76df...` | 14900339 |
| `0x5Cb6F181081301b44905F3ae15419112ecaBd8A6` | 9800 | 10 | `0x0` | `0x91bc038e...` | 21921676 |
| `0x5Cb6F181081301b44905F3ae15419112ecaBd8A6` | 50000 | 1000 | `0x0` | `0xc49d5a69...` | 21924020 |
| `0x5Cb6F181081301b44905F3ae15419112ecaBd8A6` | 8388608 | 160 | `0xFeDa24F0...` | `0x1bb6b402...` | 22024828 |
| `0x6245e67affA44a23077f0Ea7f981a8DC743a0c47` | 2500 | 60 | `0x0` | `0xacea8920...` | 23595790 |
| `0x6245e67affA44a23077f0Ea7f981a8DC743a0c47` | 950369 | 200 | `0x0` | `0x8c3a58c8...` | 23600453 |
| `0x6245e67affA44a23077f0Ea7f981a8DC743a0c47` | 840000 | 8400 | `0x0` | `0xbcd6e562...` | 23609640 |
| `0x298348d5b2e45C774E3ee4f1a0924071DfbDC8C7` | 2500 | 60 | `0x0` | `0xaff8e2d7...` | 27816878 |
| `0x298348d5b2e45C774E3ee4f1a0924071DfbDC8C7` | 970020 | 200 | `0x0` | `0x5a32511a...` | 27818036 |
| `0x298348d5b2e45C774E3ee4f1a0924071DfbDC8C7` | 930346 | 200 | `0x0` | `0x492bf542...` | 27818148 |

## `0xdbaf32b8e2d521d363d6cc476a379f85939d75cfd7eb77762f68454191b8113f`

- **token (query):** `0x45242320DBB855EeA8Fd36804C6487E10E97FCF9`
- **pair filter:** `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- **tx:** `0xa4e2142c62655dda7d57dc98627e0e677899bb1e879d3fbfe48bb2d542d21f84`
- **block:** 12251536
- **tick:** 117752
- **hookData:** `0x`
- **first seen:** 2026-08-17T05:05:02.420Z
- **last seen:** 2026-08-17T05:05:02.420Z

```json
{
  "currency0": "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  "currency1": "0x45242320DBB855EeA8Fd36804C6487E10E97FCF9",
  "fee": 8388608,
  "tickSpacing": 100,
  "hooks": "0xFeDa24F0d3805170E7566cE617CfBa01cE05D080"
}
```

## `0x781f4bd64678be81a559f58bb124c570fb86abc04831f1c41212984340df9a12`

- **token (query):** `0x45242320DBB855EeA8Fd36804C6487E10E97FCF9`
- **pair filter:** `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- **tx:** `0xd6b8ec8ad91fc5457f194faa0f904a2dcdf4317931fac3a18e0cab6c0fc5ed71`
- **block:** 12455648
- **tick:** 109506
- **hookData:** `0x`
- **first seen:** 2026-08-17T05:05:02.420Z
- **last seen:** 2026-08-17T05:05:02.420Z

```json
{
  "currency0": "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  "currency1": "0x45242320DBB855EeA8Fd36804C6487E10E97FCF9",
  "fee": 8388608,
  "tickSpacing": 60,
  "hooks": "0x96CE193F25db9b75743332bB7C94e545f1a225C3"
}
```

## `0xd33c8fd38b06e989cdbd4dffdefab71c4bdd415b24964c8d69e38ff35b068f92`

- **token (query):** `0xe934e36A439C94017B64a3FecE66AF12099aBF50`
- **tx:** `0xd5c74c05e885ec3feed94ccbbc465ab91d687d7660692297011e49676f50e719`
- **block:** 12670814
- **tick:** 164902
- **hookData:** `0x`
- **first seen:** 2026-08-18T03:06:20.232Z
- **last seen:** 2026-08-18T03:06:20.232Z
- **warnings:** Contains native ETH address(0) — Float RH UFloat/AutoVault V4 reject this; use aeWETH pair.

```json
{
  "currency0": "0x0000000000000000000000000000000000000000",
  "currency1": "0xe934e36A439C94017B64a3FecE66AF12099aBF50",
  "fee": 10000,
  "tickSpacing": 200,
  "hooks": "0x0000000000000000000000000000000000000000"
}
```

## `0x678cd61c78b8370125dbea50208dc52b75b5ca0b8f63385c96423e620a9eb0df`

- **token (query):** `0xe934e36A439C94017B64a3FecE66AF12099aBF50`
- **tx:** `0xfc7cd9f447e61aa3e9c7c4573f65779c0e028630e2ee900099ab75ab55b154d5`
- **block:** 12673199
- **tick:** 375363
- **hookData:** `0x`
- **first seen:** 2026-08-18T03:06:20.232Z
- **last seen:** 2026-08-18T03:06:20.232Z

```json
{
  "currency0": "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
  "currency1": "0xe934e36A439C94017B64a3FecE66AF12099aBF50",
  "fee": 985000,
  "tickSpacing": 19700,
  "hooks": "0x0000000000000000000000000000000000000000"
}
```

## `0x7aadc9bfce4c817db0b168ee872ea459834b28de682b85be95745123a98a7187`

- **token (query):** `0xe934e36A439C94017B64a3FecE66AF12099aBF50`
- **tx:** `0x053497afd9593d665bc7a9d8ffaa33f4e087bb9a1ab25ae764096b774ba42c6c`
- **block:** 12675794
- **tick:** 161189
- **hookData:** `0x`
- **first seen:** 2026-08-18T03:06:20.232Z
- **last seen:** 2026-08-18T03:06:20.232Z
- **warnings:** Contains native ETH address(0) — Float RH UFloat/AutoVault V4 reject this; use aeWETH pair.

```json
{
  "currency0": "0x0000000000000000000000000000000000000000",
  "currency1": "0xe934e36A439C94017B64a3FecE66AF12099aBF50",
  "fee": 850000,
  "tickSpacing": 17000,
  "hooks": "0x0000000000000000000000000000000000000000"
}
```

## `0xca8e76df5887a11793c66b6ccc6ca980794b66b81b92012e2505ff0fa5521c54`

- **token (query):** `0x45242320DBB855EeA8Fd36804C6487E10E97FCF9`
- **pair filter:** `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- **tx:** `0x4ffeb1078cc335be962fa1b526758ed0551f33d71fc3d5681f539c46985eba3c`
- **block:** 14900339
- **tick:** 115194
- **hookData:** `0x`
- **first seen:** 2026-08-17T05:05:02.420Z
- **last seen:** 2026-08-17T05:05:02.420Z

```json
{
  "currency0": "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  "currency1": "0x45242320DBB855EeA8Fd36804C6487E10E97FCF9",
  "fee": 25400,
  "tickSpacing": 508,
  "hooks": "0x0000000000000000000000000000000000000000"
}
```

## `0x91bc038e735441f21d1b933178b5d76281c233098fc8b7587133138d78f1697a`

- **token (query):** `0x5Cb6F181081301b44905F3ae15419112ecaBd8A6`
- **pair filter:** `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- **tx:** `0x38e1a8e50e063929e67fcafa88aec149247f92ea3d0e0536a3818e7a3d69f615`
- **block:** 21921676
- **tick:** 136222
- **hookData:** `0x`
- **first seen:** 2026-08-17T05:05:44.497Z
- **last seen:** 2026-08-17T05:05:44.497Z

```json
{
  "currency0": "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  "currency1": "0x5Cb6F181081301b44905F3ae15419112ecaBd8A6",
  "fee": 9800,
  "tickSpacing": 10,
  "hooks": "0x0000000000000000000000000000000000000000"
}
```

## `0xc49d5a691eaaa089f41bccff900110b1ae12e083831ad83e974285e76a74fb2a`

- **token (query):** `0x5Cb6F181081301b44905F3ae15419112ecaBd8A6`
- **pair filter:** `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- **tx:** `0x5d5480cae1fcd98d03005775fdd0bd9849251c567e8fcfcdfd2f9e90474abfab`
- **block:** 21924020
- **tick:** 154999
- **hookData:** `0x`
- **first seen:** 2026-08-17T05:05:44.497Z
- **last seen:** 2026-08-17T05:05:44.497Z

```json
{
  "currency0": "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  "currency1": "0x5Cb6F181081301b44905F3ae15419112ecaBd8A6",
  "fee": 50000,
  "tickSpacing": 1000,
  "hooks": "0x0000000000000000000000000000000000000000"
}
```

## `0x1bb6b402c25f63eb413cbe25e54532d1d76b170382740a0bb08b6462b54b765d`

- **token (query):** `0x5Cb6F181081301b44905F3ae15419112ecaBd8A6`
- **pair filter:** `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- **tx:** `0x0431e3456d9b31781a9d21a76c8539aeb895e9a800557bb866ad6b1b5be53caf`
- **block:** 22024828
- **tick:** 132873
- **hookData:** `0x`
- **first seen:** 2026-08-17T05:05:44.497Z
- **last seen:** 2026-08-17T05:05:44.497Z

```json
{
  "currency0": "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  "currency1": "0x5Cb6F181081301b44905F3ae15419112ecaBd8A6",
  "fee": 8388608,
  "tickSpacing": 160,
  "hooks": "0xFeDa24F0d3805170E7566cE617CfBa01cE05D080"
}
```

## `0xacea8920877840033f0275c37f9b61550b5326917e948bcf8339714d96f9521a`

- **token (query):** `0x6245e67affA44a23077f0Ea7f981a8DC743a0c47`
- **tx:** `0xbe6b90c58c017b4754a6a6ee6d65be9a682d2b79de0142954ae345f1dce8f35c`
- **block:** 23595790
- **tick:** 198060
- **hookData:** `0x`
- **first seen:** 2026-08-18T04:06:36.339Z
- **last seen:** 2026-08-18T04:07:55.413Z
- **warnings:** Contains native ETH address(0) — Float RH UFloat/AutoVault V4 reject this; use aeWETH pair.

```json
{
  "currency0": "0x0000000000000000000000000000000000000000",
  "currency1": "0x6245e67affA44a23077f0Ea7f981a8DC743a0c47",
  "fee": 2500,
  "tickSpacing": 60,
  "hooks": "0x0000000000000000000000000000000000000000"
}
```

## `0x8c3a58c872f8981b5115bb001910578ab635feff65bde028e5c1f697f2458a34`

- **token (query):** `0x6245e67affA44a23077f0Ea7f981a8DC743a0c47`
- **tx:** `0x94a56ddc5103c0c1aa65bdf4aa0306050a313332138ea455099604c5958a955a`
- **block:** 23600453
- **tick:** 205947
- **hookData:** `0x`
- **first seen:** 2026-08-18T04:06:36.339Z
- **last seen:** 2026-08-18T04:07:55.413Z
- **warnings:** Contains native ETH address(0) — Float RH UFloat/AutoVault V4 reject this; use aeWETH pair.

```json
{
  "currency0": "0x0000000000000000000000000000000000000000",
  "currency1": "0x6245e67affA44a23077f0Ea7f981a8DC743a0c47",
  "fee": 950369,
  "tickSpacing": 200,
  "hooks": "0x0000000000000000000000000000000000000000"
}
```

## `0xbcd6e5623ef421a08aeea2d2b6e3beb76508195d417fb1a8ab6dc57633ea668b`

- **token (query):** `0x6245e67affA44a23077f0Ea7f981a8DC743a0c47`
- **tx:** `0x1815649503332e461946650a04fef3886d83cdeb0b6d553166ad2fd9261220f0`
- **block:** 23609640
- **tick:** 373540
- **hookData:** `0x`
- **first seen:** 2026-08-18T04:06:36.339Z
- **last seen:** 2026-08-18T04:07:55.413Z

```json
{
  "currency0": "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
  "currency1": "0x6245e67affA44a23077f0Ea7f981a8DC743a0c47",
  "fee": 840000,
  "tickSpacing": 8400,
  "hooks": "0x0000000000000000000000000000000000000000"
}
```

## `0xaff8e2d7015c76fa6d9b2bedb72da7d6b305fd7b2140df3fca5c3c57e877ecfa`

- **token (query):** `0x298348d5b2e45C774E3ee4f1a0924071DfbDC8C7`
- **tx:** `0xcb4db1f96fdb3159456eabbeeaa174aec1c14e852f7e63b253aa319cdc6f6ac7`
- **block:** 27816878
- **tick:** 198060
- **hookData:** `0x`
- **first seen:** 2026-08-18T03:10:56.250Z
- **last seen:** 2026-08-18T03:10:56.250Z
- **warnings:** Contains native ETH address(0) — Float RH UFloat/AutoVault V4 reject this; use aeWETH pair.

```json
{
  "currency0": "0x0000000000000000000000000000000000000000",
  "currency1": "0x298348d5b2e45C774E3ee4f1a0924071DfbDC8C7",
  "fee": 2500,
  "tickSpacing": 60,
  "hooks": "0x0000000000000000000000000000000000000000"
}
```

## `0x5a32511ac0377ecde9cc9106b9720557f4b0a98a349d742fda78c2e8b211d08d`

- **token (query):** `0x298348d5b2e45C774E3ee4f1a0924071DfbDC8C7`
- **tx:** `0xb80601b23e6f97c1c07271006faae290173914f51c64430863d3776ed2d039eb`
- **block:** 27818036
- **tick:** 218628
- **hookData:** `0x`
- **first seen:** 2026-08-18T03:10:56.250Z
- **last seen:** 2026-08-18T03:10:56.250Z
- **warnings:** Contains native ETH address(0) — Float RH UFloat/AutoVault V4 reject this; use aeWETH pair.

```json
{
  "currency0": "0x0000000000000000000000000000000000000000",
  "currency1": "0x298348d5b2e45C774E3ee4f1a0924071DfbDC8C7",
  "fee": 970020,
  "tickSpacing": 200,
  "hooks": "0x0000000000000000000000000000000000000000"
}
```

## `0x492bf542e315b84adcf852f400ca4683571296fae6a202ef0f86d1d7b98a4724`

- **token (query):** `0x298348d5b2e45C774E3ee4f1a0924071DfbDC8C7`
- **tx:** `0xdd3ca3ca9ac9214447575599ae06aa89b1c963aa6e8670b304f5209c1df1e305`
- **block:** 27818148
- **tick:** 217931
- **hookData:** `0x`
- **first seen:** 2026-08-18T03:10:56.250Z
- **last seen:** 2026-08-18T03:10:56.250Z
- **warnings:** Contains native ETH address(0) — Float RH UFloat/AutoVault V4 reject this; use aeWETH pair.

```json
{
  "currency0": "0x0000000000000000000000000000000000000000",
  "currency1": "0x298348d5b2e45C774E3ee4f1a0924071DfbDC8C7",
  "fee": 930346,
  "tickSpacing": 200,
  "hooks": "0x0000000000000000000000000000000000000000"
}
```
