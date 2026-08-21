// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ICLFactory.sol";

/// @notice Adapter to make ICLFactory compatible with IUniswapV3Factory interface
/// @dev This allows existing libraries to work with SlipStream by converting fee to tickSpacing
interface IUniswapV3FactoryAdapter {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @dev Adapter implementation
contract UniswapV3FactoryAdapter is IUniswapV3FactoryAdapter {
    ICLFactory public immutable clFactory;
    mapping(uint24 => int24) public feeToTickSpacing; // Map fee to tickSpacing
    
    constructor(address _clFactory) {
        clFactory = ICLFactory(_clFactory);
        // Common mappings - adjust based on your pool configuration
        feeToTickSpacing[100] = 1;
        feeToTickSpacing[500] = 10;
        feeToTickSpacing[3000] = 60;
        feeToTickSpacing[10000] = 200;
    }
    
    function getPool(address tokenA, address tokenB, uint24 fee) external view override returns (address pool) {
        int24 tickSpacing = feeToTickSpacing[fee];
        require(tickSpacing != 0, "Fee not mapped to tickSpacing");
        return clFactory.getPool(tokenA, tokenB, tickSpacing);
    }
    
    function setFeeMapping(uint24 fee, int24 tickSpacing) external {
        feeToTickSpacing[fee] = tickSpacing;
    }
}

