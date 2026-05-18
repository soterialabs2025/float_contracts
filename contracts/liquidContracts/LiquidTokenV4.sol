// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title LiquidTokenV4
/// @notice Share token for `LiquidVaultV4`; mint/burn restricted to the wired vault.
contract LiquidTokenV4 is ERC20, Ownable {
    address public liquidVaultV4;
    bool public contractSetUp;

    event VaultUpdated(address indexed liquidVaultV4);
    event ContractSetUp(address indexed caller);

    constructor() ERC20("Liquid Token V4", "LTOKV4") Ownable(msg.sender) {}

    function setUpContract(address _liquidVaultV4) external onlyOwner {
        require(_liquidVaultV4 != address(0), "Invalid vault address");
        liquidVaultV4 = _liquidVaultV4;
        contractSetUp = true;
        emit VaultUpdated(_liquidVaultV4);
        emit ContractSetUp(_msgSender());
    }

    function mint(address to, uint256 amount) external {
        require(_msgSender() == liquidVaultV4, "Only vault can mint");
        require(to != address(0), "Mint to zero address");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(_msgSender() == liquidVaultV4, "Only vault can burn");
        _burn(from, amount);
    }
}
