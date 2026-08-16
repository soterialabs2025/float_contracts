// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title V4Deployments4663
/// @notice Uniswap v4 + reused Float RH infra on Robinhood chain (chainId 4663).
library V4Deployments4663 {
    uint256 internal constant CHAIN_ID = 4663;
    /// @dev aeWETH (not Base WETH, not native ETH).
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Reused from live RH AutoVault / UFloat V3 infra (ADDRESSES_2.md).
    address internal constant OPERATOR_REGISTRY = 0x7df1120a04D82eA92EA2d5AA005e3316B37b936E;
    address internal constant FEE_MANAGER = 0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE;

    address internal constant DEMETER_RH_1 = 0x3ec00017066Eb2e2348D82d0e21D5fDB3357CE16;
    address internal constant DEMETER_RH_2 = 0xa16c8cc08674F7c120A64d94f432377D427901a0;
    address internal constant TRITON_RH_1 = 0xbED21b27411A80a557bBA5BDd4e31E05E09E09f4;
    address internal constant TRITON_RH_2 = 0xDaFb1B9789F4ECb75A006F65F99081802c871Ed4;
}
