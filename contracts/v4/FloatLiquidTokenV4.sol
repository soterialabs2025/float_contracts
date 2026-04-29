// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IFloatV4ContractManager.sol";

/**
 * @title FloatLiquidTokenV4
 * @notice Share token for `FloatVaultV4`; mint/burn restricted to the vault registered as `FloatVaultV4` on the manager.
 */
contract FloatLiquidTokenV4 is ERC20, Ownable {
    address public floatVaultV4;
    IFloatV4ContractManager public manager;
    bool public contractSetUp;

    event VaultUpdated(address indexed floatVaultV4);
    event ContractSetUp(address indexed caller);

    constructor(address _managerAddr) ERC20("Liquid Token V4", "LTOKV4") Ownable(msg.sender) {
        require(_managerAddr != address(0), "Invalid manager address");
        manager = IFloatV4ContractManager(_managerAddr);
    }

    function setUpContract() external onlyOwner {
        floatVaultV4 = manager.getAddress("FloatVaultV4");
        require(floatVaultV4 != address(0), "Invalid vault address");
        contractSetUp = true;
        emit VaultUpdated(floatVaultV4);
        emit ContractSetUp(_msgSender());
    }

    function mint(address to, uint256 amount) external {
        require(_msgSender() == floatVaultV4, "Only vault can mint");
        require(to != address(0), "Mint to zero address");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(_msgSender() == floatVaultV4, "Only vault can burn");
        _burn(from, amount);
    }
}
