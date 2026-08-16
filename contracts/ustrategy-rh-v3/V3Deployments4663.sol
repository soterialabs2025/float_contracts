// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title V3Deployments4663
/// @notice Uniswap v3 + reused Float RH infra on Robinhood chain (chainId 4663).
library V3Deployments4663 {
    uint256 internal constant CHAIN_ID = 4663;
    /// @dev aeWETH (not Base WETH, not native ETH).
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant NPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address internal constant SWAP_ROUTER02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address internal constant QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;

    /// @dev Reused from live RH AutoVault Uni V3/V4 infra (ADDRESSES_2.md).
    address internal constant OPERATOR_REGISTRY = 0x7df1120a04D82eA92EA2d5AA005e3316B37b936E;
    address internal constant FEE_MANAGER = 0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE;

    address internal constant DEMETER_RH_1 = 0x3ec00017066Eb2e2348D82d0e21D5fDB3357CE16;
    address internal constant DEMETER_RH_2 = 0xa16c8cc08674F7c120A64d94f432377D427901a0;
    address internal constant TRITON_RH_1 = 0xbED21b27411A80a557bBA5BDd4e31E05E09E09f4;
    address internal constant TRITON_RH_2 = 0xDaFb1B9789F4ECb75A006F65F99081802c871Ed4;
}
