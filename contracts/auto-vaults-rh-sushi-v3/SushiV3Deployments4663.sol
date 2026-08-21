// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Robinhood Chain (4663) SushiSwap V3 / clAMM deployments.
/// @dev RedSnwapper is documented for ops/API routes only — not used by vault remint/harvest.
library SushiV3Deployments4663 {
    uint256 internal constant CHAIN_ID = 4663;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant FACTORY = 0xE51960f1B45f1C9FB6D166E6a884F866fC70433B;
    address internal constant NPM = 0x51d0e5188afe12d502e29D982d20C190e7816107;
    address internal constant QUOTER = 0x3E290e5E01818002A0b672148BdC7514D861C7B3;
    address internal constant TICK_LENS = 0x80126A8D806D029Ac551Ac6f30BAF06b785175d1;
    /// @dev Aggregator facade; requires off-chain executorData — unused on critical vault path.
    address internal constant RED_SNWAPPER = 0x8E6fD69A77e88ee20Ba4B4fBd59DfCDA3EC0E98A;
    bytes32 internal constant POOL_INIT_CODE_HASH =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
}
