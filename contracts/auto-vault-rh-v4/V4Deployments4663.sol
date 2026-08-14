// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title V4Deployments4663
/// @notice Uniswap v4 stack on Robinhood Chain mainnet (chainId 4663).
/// @dev Addresses from https://developers.uniswap.org/deployments and Uniswap contracts/deployments/4663.md
library V4Deployments4663 {
    uint256 internal constant CHAIN_ID = 4663;
    /// @dev aeWETH (WETH9-compatible wrapped native)
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
}
