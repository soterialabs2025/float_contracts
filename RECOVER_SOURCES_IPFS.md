# Recover `FloatSwaprouter.sol` (and interfaces) from `FloatSwapRouter_metadata.json`

Remix metadata for this build **does not include** inline `sources.*.content` — only **keccak256** + **IPFS** URLs. The large `FloatSwapRouter.json` artifact is compile output (AST/debug), not full Solidity text.

## Main contract

| File (compile path) | IPFS CID |
|---------------------|----------|
| `.claude/worktrees/zen-hellman/contracts/FloatSwaprouter.sol` | `QmTVkpwu9PmZjeiF2DQjjibT8CkMev3dCG9RRHYzJ6BQsK` |

## Interfaces (same metadata)

| Path | CID |
|------|-----|
| `interfaces/IAllowanceTransfer.sol` | `QmWhqFaWt2yzK65bGTAwV6o5wLMCQzjyEpdZdqWgVVt5PE` |
| `interfaces/IContractManager.sol` | `QmeNCQHAQgG9v2pogcLQGGTGE1yU9rP4nZUirNJB8hEpij` |
| `interfaces/IQuoterV2.sol` | `QmUitqyKRMAMRPH4Q5b7Lg6N4gXY5wJ5MbKCFJPPedZKs4` |
| `interfaces/ISwapRouter.sol` | `QmNrqj1K1Vj8F5zUDn7gZTDq2BG9ALQPdJErRj5UVkgvBd` |
| `interfaces/IUniswapV2Router01.sol` | `QmP8k8u7jWqvyV5isWqj3qagtKZxjfZuPRRzeWEqQ55paA` |
| `interfaces/IUniswapV2Router02.sol` | `QmSJKVgEnHsTgHSwQzKR4r4aGjFEHvH5CoU1mupK3dePYD` |
| `interfaces/IUniversalRouter.sol` | `QmdF5TvzTSezHXtT2p2Sg3iQcLgMg9kEH7gX48Tr3iqHcG` |
| `interfaces/IV3SwapRouterMinimal.sol` | `QmRf78gYdASpkuz4dtYMeb2HHbN8RmKwZv2vSAXATR4ZEx` |

## Commands (local [IPFS](https://docs.ipfs.tech/install/) daemon)

```bash
ipfs cat QmTVkpwu9PmZjeiF2DQjjibT8CkMev3dCG9RRHYzJ6BQsK > contracts/FloatSwaprouter.sol
# repeat for each CID into the matching path under zen-hellman/
```

Public gateways often **504** for these CIDs; local `ipfs cat` or a pinned node is the reliable path.

## Repo helper

```bash
node scripts/list-metadata-ipfs-cids.mjs artifacts/FloatSwapRouter_metadata.json
```

## Three artifacts (what they are)

| File | Role |
|------|------|
| `artifacts/FloatSwapRouter.json` | Remix/HH-style build (bytecode, debug, etc.) — not a source bundle |
| `artifacts/FloatSwapRouter_metadata.json` | Compiler metadata + **IPFS** source pointers (no `content` here) |
| `contracts/FloatSwaprouter.sol` | Should be the **recovered** `.sol` at `zen-hellman/contracts/FloatSwaprouter.sol` (path matches metadata) |
