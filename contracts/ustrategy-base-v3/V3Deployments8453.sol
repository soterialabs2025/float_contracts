// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title V3Deployments8453
/// @notice Uniswap v3 + reused Float infra on Base mainnet (chainId 8453).
library V3Deployments8453 {
    uint256 internal constant CHAIN_ID = 8453;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address internal constant SWAP_ROUTER02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant QUOTER_V2 = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;

    /// @dev Reused from live Base Float / UFloat V4 infra (ADDRESSES_2.md).
    address internal constant OPERATOR_REGISTRY = 0x704618C4E8C201F45536DFD583911F8335e853Dd;
    address internal constant FEE_MANAGER = 0x9f6e579117BeAd116E25CfeC43e319637DE0bCEe;
    /// @dev FloatContractManagerV4 — docs only; V3 UFloat does not call it.
    address internal constant MANAGER_V4_DOCS = 0xD12D64925340Ffc277d79b02A212Dd576701EaC9;

    address internal constant DEMETER = 0x208169B1321A09e614a68B06b7F600Dc0E007212;
    address internal constant TRITON = 0x66d60E991D09447245d668671d079b57eB48f58E;
}
