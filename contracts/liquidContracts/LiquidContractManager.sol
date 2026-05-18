// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol"; 
import "./interfaces/IUniswapV3Factory.sol";

/**
 * @title ContractManager
 * @author TB_Contracts Team
 * @notice Central registry for managing protocol contract addresses
 * @dev This contract serves as the central hub for storing and retrieving
 *      addresses of all protocol contracts. It provides a single source of
 *      truth for contract addresses and allows for easy updates when contracts
 *      are upgraded or redeployed.
 * @custom:version 1.0.0
 * @custom:last-updated 2025-09-05 
 */

contract LiquidContractManager is Ownable {

    address private constant v3FactoryAddr = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address private constant baseWETH = 0x4200000000000000000000000000000000000006;
    uint24 private constant V3_FEE = 10_000;

    /// @notice Mapping of contract names to their addresses
    /// @dev Keys are contract names (e.g., "Oracle", "Rewards", "TerminalBank")
    ///      Values are the corresponding contract addresses
    mapping(string => address) public addresses;

    /// @notice Events
    event AddressSet(string indexed name, address indexed contractAddress);
    event AddressDeleted(string indexed name);
    event AddressUpdated(string indexed name, address indexed oldAddress, address indexed newAddress);

    /// @notice Constructor initializes the ContractManager contract
    /// @dev Sets the deployer as the owner of the contract
    constructor() Ownable(msg.sender) {}


    /// @notice Sets the address for a given contract name. Only callable by the owner.
    /// @dev Emits AddressSet every time, and AddressUpdated if the address changes from a nonzero value.
    /// @dev Validates that the address is not zero address.
    /// @param _name The name of the contract to set the address for.
    /// @param _address The address to associate with the given name.
    function setAddress(string memory _name, address _address) public payable onlyOwner {
        require(_address != address(0), "Cannot set zero address");
        
        // Get the current address associated with the name
        address oldAddress = addresses[_name];
        // Update the mapping with the new address
        addresses[_name] = _address;
        // Always emit AddressSet event for transparency
        emit AddressSet(_name, _address);
        // If the old address was set and is different from the new one, emit AddressUpdated
        if (oldAddress != address(0) && oldAddress != _address) {
            emit AddressUpdated(_name, oldAddress, _address);
        }
    }

    /// @notice Retrieves the address associated with a given contract name.
    /// @param _name The name of the contract whose address is being requested.
    /// @return The address associated with the given name, or address(0) if not set.
    function getAddress(string memory _name) public view returns (address) {
        return addresses[_name];
    }

    /// @notice Checks if an address is set for a given contract name.
    /// @param _name The name of the contract to check.
    /// @return True if an address is set (non-zero), false otherwise.
    function isAddressSet(string memory _name) public view returns (bool) {
        return addresses[_name] != address(0);
    }

    /// @notice Retrieves multiple contract addresses in a single call.
    /// @param _names Array of contract names to get addresses for.
    /// @return Array of addresses corresponding to the names.
    function getAddresses(string[] memory _names) public view returns (address[] memory) {
        address[] memory result = new address[](_names.length);
        for (uint256 i = 0; i < _names.length; i++) {
            result[i] = addresses[_names[i]];
        }
        return result;
    }

    /// @notice Sets multiple contract addresses in a single transaction. Only callable by the owner.
    /// @dev Batch operation that calls setAddress for each name-address pair.
    /// @param _names Array of contract names to set addresses for.
    /// @param _addresses Array of addresses corresponding to the names.
    function setAddresses(
        string[] memory _names, 
        address[] memory _addresses
    ) external payable onlyOwner {
        require(_names.length == _addresses.length, "Arrays length mismatch");
        require(_names.length > 0, "Arrays cannot be empty");
        require(_names.length <= 10, "Too many addresses (max 10)"); // Prevent gas limit issues
        
        for (uint256 i = 0; i < _names.length; i++) {
            setAddress(_names[i], _addresses[i]);
        }
    }

    /// @notice Deletes the address associated with a given contract name. Only callable by the owner.
    /// @param _name The name of the contract whose address should be deleted.
    /// @dev Sets the address to address(0) and emits an AddressDeleted event.
    function deleteAddress(string memory _name) external payable onlyOwner {
        addresses[_name] = address(0);
        emit AddressDeleted(_name);
    }

    /// @notice Changes the asset in the Strategy contract and updates all related contracts
    /// @dev Gets pool address from Uniswap V3 factory for new asset / WETH pair, then calls changeAsset on Strategy
    /// @dev Then calls updateAsset() on Vault and SwapRouter to update their references
    /// @dev Only callable by the owner or Demeter
    function changeStrategyAsset(address _newAssetAddr) external {
        address demeterAddr = addresses["Demeter"];
        require(owner() == _msgSender() || demeterAddr == _msgSender(), "Unauthorized");

        require(_newAssetAddr != address(0), "New asset address not set");
        require(_newAssetAddr != baseWETH, "WETH cannot be strategy asset");

        address vaultAddr = addresses["LiquidVault"];
        address strategyAddr = addresses["LiquidStrategy"];
        address swapRouterAddr = addresses["LiquidSwapRouter"];

        require(strategyAddr != address(0), "Strategy address not set");

        // Check both token orderings - getPool returns same pool either way
        address newPoolV3Addr = IUniswapV3Factory(v3FactoryAddr).getPool(_newAssetAddr, baseWETH, V3_FEE);
        if (newPoolV3Addr == address(0)) {
            newPoolV3Addr = IUniswapV3Factory(v3FactoryAddr).getPool(baseWETH, _newAssetAddr, V3_FEE);
        }
        require(newPoolV3Addr != address(0), "Pool does not exist for asset/WETH");

        // Call changeAsset on Strategy first; only persist new asset when it succeeds
        _bubbleCall(
            strategyAddr,
            abi.encodeWithSignature("changeAsset(address,address)", _newAssetAddr, newPoolV3Addr)
        );

        addresses["LiquidASSET"] = _newAssetAddr;
        addresses["LiquidAssetPoolV3"] = newPoolV3Addr;

        if (vaultAddr != address(0)) {
            _bubbleCall(vaultAddr, abi.encodeWithSignature("updateAsset()"));
        }

        if (swapRouterAddr != address(0)) {
            _bubbleCall(swapRouterAddr, abi.encodeWithSignature("updateAsset()"));
        }
    }

    /// @dev Forwards revert data from the callee (e.g. `Unauthorized()`, `asset=0`) instead of a generic string.
    function _bubbleCall(address target, bytes memory data) private {
        (bool success, bytes memory returndata) = target.call(data);
        if (!success) {
            if (returndata.length > 0) {
                assembly ("memory-safe") {
                    revert(add(returndata, 32), mload(returndata))
                }
            }
            revert("call failed");
        }
    }
}    