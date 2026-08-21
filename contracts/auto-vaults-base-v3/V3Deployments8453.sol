// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title V3Deployments8453
/// @notice Uniswap v3 stack on Base mainnet (chainId 8453).
library V3Deployments8453 {
    uint256 internal constant CHAIN_ID = 8453;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address internal constant SWAP_ROUTER02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant QUOTER_V2 = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;

    /// @dev Reused from live Base AutoVault / UFloat infra (ADDRESSES_2.md).
    address internal constant OPERATOR_REGISTRY = 0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8;
    address internal constant FEE_MANAGER = 0x9f6e579117BeAd116E25CfeC43e319637DE0bCEe;
}
