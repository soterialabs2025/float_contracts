// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPoolManagerV4
 * @notice Minimal interface for the Uniswap V4 PoolManager, limited to the
 *         state-read functions used by RouletteStrategyV4 and LiquidityLibraryV4.
 * @dev Full interface: @uniswap/v4-core/src/interfaces/IPoolManager.sol
 *      Base mainnet: 0x498581fF718922c3f8e6A244956aF099B2652b2b
 *
 *      getSlot0 is exposed via StateLibrary in v4-core.
 *      The function signature used here matches StateLibrary.getSlot0:
 *        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
 */
interface IPoolManagerV4 {
    /**
     * @notice Read the current price and tick for a pool.
     * @param poolId  keccak256(abi.encode(PoolKey)) — use LiquidityLibraryV4.poolId()
     * @return sqrtPriceX96  Current sqrt price in X96 fixed-point
     * @return tick          Current active tick
     * @return protocolFee   Protocol fee (hundredths of a bip)
     * @return lpFee         LP fee (hundredths of a bip)
     */
    function getSlot0(bytes32 poolId)
        external view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}
