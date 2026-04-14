// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title V4Deployments8453
/// @notice Uniswap v4 stack on Base mainnet (chainId 8453). Wrapped native is chain-specific — supply at deploy time, not here.
/// @dev Addresses from https://docs.uniswap.org/contracts/v4/deployments (Base section). Re-verify on that page before production.
library V4Deployments8453 {
    uint256 internal constant CHAIN_ID = 8453;

    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant STATE_VIEW = 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71;
    address internal constant QUOTER = 0x0d5e0F971ED27FBfF6c2837bf31316121532048D;
    address internal constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
}
