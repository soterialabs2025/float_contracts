// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPositionManagerV4
 * @notice Minimal interface for the Uniswap V4 PositionManager.
 * @dev Full interface: @uniswap/v4-periphery/src/interfaces/IPositionManager.sol
 *      Base mainnet: 0x7C5f5A4bBd8fD63184577525326123B519429bDc
 */
interface IPositionManagerV4 {
    /**
     * @notice Execute a sequence of liquidity actions (mint, increase, decrease, burn, settle, take …)
     * @param unlockData  ABI-encoded (bytes actions, bytes[] params)
     * @param deadline    Transaction deadline timestamp
     */
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;

    /**
     * @notice The tokenId that will be assigned to the NEXT minted position.
     * @dev Used to predict a tokenId before calling modifyLiquidities with MINT_POSITION.
     */
    function nextTokenId() external view returns (uint256);

    /**
     * @notice Returns the liquidity of an existing position by tokenId.
     */
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
}
