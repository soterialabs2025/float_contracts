# Auto Vault — names (Base)

**Case-insensitive.** Strip trailing `vault` / `pool` / `token` before lookup.

---

## Deployed packages (name → vault)

Use for deposit / withdraw / NAV when vault is known.

| Name | ASSET | Vault | Strategy |
|------|-------|-------|----------|
| `surplus` | `0xC52aeDec3374422d7510E294cfAa90799595CBa3` | `0x8f6b79745E8a2f59fadc77508399104B5aceA4E7` | `0x03B736517E613db7dDdB64C13485bB55e58d5721` |
| `nook` | `0xb233BDFFD437E60fA451F62c6c09D3804d285Ba3` | `0x12253670cd255F89DB22Def582eAB8bB17f580Aa` | `0xC60B19BE4b62b6B05fFffA797866Be4c092DC57B` |

---

## Known tokens (name → ASSET)

Use when the user asks **“is there an X vault?”** / **“does molten have a vault?”**:

1. Look up **ASSET** here.
2. Call `factory.registry(asset)` → `(strategy, vault, active)`.
3. If `strategy == 0` → no Auto vault for that token yet.
4. If `active == false` → deployed but inactive.
5. If active → yes; report `vault` / `strategy` (and cache into Deployed packages if missing).

| Name | ASSET |
|------|-------|
| `sairi` | `0xde61878b0b21ce395266c44d4d548d1c72a3eb07` |
| `miroshark` | `0xd7bc6a05a56655fb2052f742b012d1dfd66e1ba3` |
| `edge` | `0x62abe92f50c518165a5c010fe59f35023197fba3` |
| `litcoin` | `0x316ffb9c875f900adcf04889e415cc86b564eba3` |
| `lfi` | `0x3722264ab15a1dfce5a5af89e6547f7949a8aba3` |
| `clawbank` | `0x16332535e2c27da578bc2e82beb09ce9d3c8eb07` |
| `gitlawb` | `0x5f980dcfc4c0fa3911554cf5ab288ed0eb13dba3` |
| `cred` | `0xab3f23c2abcb4e12cc8b593c218a7ba64ed17ba3` |
| `clawnch` | `0xa1f72459dfa10bad200ac160ecd78c6b77a747be` |
| `molt` | `0xb695559b26bb2c9703ef1935c37aeae9526bab07` |
| `nook` | `0xb233bdffd437e60fa451f62c6c09d3804d285ba3` |
| `hermesos` | `0x95ccfd2b81a9667b0cc979992632f98fc853eba3` |
| `kellyclaude` | `0x50d2280441372486beecdd328c1854743ebacb07` |
| `juno` | `0x4e6c9f48f73e54ee5f3ab7e2992b2d733d0d0b07` |
| `darksol` | `0x00cb1fbca324d51325a7264d54072bc073c28ba3` |
| `doppel` | `0xf27b8ef47842e6445e37804896f1bc5e29381b07` |
| `felix` | `0xf30bf00edd0c22db54c9274b90d2a4c21fc09b07` |
| `bv7x` | `0xd88fd4a11255e51f64f78b4a7d74456325c2d8dc` |
| `clawd` | `0x9f86db9fc6f7c9408e8fda3ff8ce4e78ac7a6b07` |
| `molten` | `0x59c0d5c34c301ac0600147924d6c9be22a2f0b07` |
| `botcoin` | `0xa601877977340862ca67f816eb079958e5bd0ba3` |
| `regent` | `0x6f89bca4ea5931edfcb09786267b251dee752b07` |
| `selfclaw` | `0x9ae5f51d81ff510bf961218f833f79d57bfbab07` |
| `cody` | `0x3977fc913db86b01a257232c568317798b903b07` |
| `gitbank` | `0xc21dd0ee043930711c2a3e55f39c7d3144d09b07` |
| `supergemma` | `0x572c4fa77623652411574c51b5ddb7e1b750aba3` |
| `grantr` | `0x753f2af0f46361c9ae6fc347797f99b0c9e82ba3` |
| `wake` | `0x50c2cc97c4f487aa0cd742ab4b6afe8b8511bba3` |
| `aeon` | `0xbf8e8f0e8866a7052f948c16508644347c57aba3` |
| `berry` | `0x778d347b2ffbadf31a2a1be9cf42b4c7ba8b1ba3` |
| `blocktronics` | `0x7afe438411ee3959c7de6f7fb76bf9c769320ba3` |
| `orlix` | `0x799c28bac95b3e0b26534d1e9a586511895ecba3` |
| `1clawai` | `0x61d91cff0fc9fbbdb89f505cf8a7422bf95fdba3` |
| `evo` | `0x721b072dbb616f29eea73ac004e03fd4e884bba3` |
| `surplus` | `0xc52aedec3374422d7510e294cfaa90799595cba3` |

Factory: `0x0Fbca262D7CeBe0F5Df9fE6Eda4b8Ac9e84E7949`
