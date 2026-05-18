// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";  
import "@openzeppelin/contracts/access/Ownable.sol";  
import "./interfaces/IContractManager.sol";
/**
 * @title LiquidTokens
 * @author TB_Contracts Team
 * @notice ERC20 token representing shares in the LiquidASSET/WETH concentrated liquidity pool
 * @dev This token is minted when users deposit into the LiquidVault
 * @dev Users burn these tokens to withdraw their proportional share of the pool
 */
contract LiquidToken is ERC20, Ownable {
    
    // The vault contract that can mint/burn these tokens
    address public LiquidVault;
    IContractManager public manager;
    bool public contractSetUp;
    event VaultUpdated(address indexed LiquidVault);
    event ContractSetUp(address indexed caller);
    
    constructor(address _managerAddr) ERC20("Liquid Token", "LTOKEN") Ownable(msg.sender) {
        require(_managerAddr != address(0), "Invalid manager address");
        manager = IContractManager(_managerAddr);
    }
    /**
     * @notice Initialize the contract by setting the vault address
     * @dev onlyOwner
     */
    function setUpContract() external onlyOwner {
        LiquidVault = manager.getAddress("LiquidVault");
        require(LiquidVault != address(0), "Invalid vault address");
        contractSetUp = true;
        emit VaultUpdated(LiquidVault);
        emit ContractSetUp(_msgSender());
    }
    
    /**
     * @notice Mint tokens to an address
     * @dev onlyVault
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external {
        require(_msgSender() == LiquidVault, "Only vault can mint");
        require(to != address(0), "Mint to zero address");
        _mint(to, amount);
    }
    
    /**
     * @notice Burn tokens from an address
     * @dev onlyVault
     * @param from The address to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burn(address from, uint256 amount) external {
        require(_msgSender() == LiquidVault, "Only vault can burn");
        _burn(from, amount);
    }
}

