// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
 
/// @title IOracle Interface for Terminal Bank Oracle
/// @author TB_Contracts Team
/// @notice Interface for Terminal Bank Oracle system
/// @dev Compatible with both original Oracle.sol and new Terminal Oracle contracts

interface IOracle {
  /// @notice Get the current average price of TERMS in WETH
  /// @return price Current TERMS/WETH price
  function getAveragePrice() external returns(uint256 price);
  
  /// @notice Get the current price average for token0
  /// @return price Average price of token0
  function readPrice0Average() external view returns (uint256 price); 
  
  /// @notice Get price quote for a swap
  /// @param factory Uniswap factory address
  /// @param amountIn Input amount
  /// @param path Swap path
  /// @return amountOut Output amount
  function getQuote(address factory, uint256 amountIn, address[] calldata path) external view returns(uint256 amountOut);
  
  /// @notice Check if TERMS price period has elapsed
  /// @return elapsed True if period has elapsed
  function readTimeElapsed() external view returns(bool elapsed);
  
  /// @notice Check if token price period has elapsed
  /// @param tokenAddress Token address to check
  /// @return elapsed True if period has elapsed
  function readTimeElapsedTkn(address tokenAddress) external returns(bool elapsed);
  
  /// @notice Get average price of token per WETH
  /// @param tokenAddress Token address
  /// @return price Average price of token in WETH
  function getTknAvgPricePerWeth(address tokenAddress) external returns(uint256 price);
  
  /// @notice Get average price of token (view function)
  /// @param tokenAddress Token address
  /// @return price Average price of token
  function getTknAvgPrice(address tokenAddress) external view returns(uint256 price);
  
  /// @notice Set up a token pair for price tracking
  /// @param tokenAddress Token address to track
  function setPair(address tokenAddress) external;
} 