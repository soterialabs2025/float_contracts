// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title FloatContractManagerV4
 * @notice Registry for v4 stack deployments (`FloatVaultV4`, `FloatStrategyV4`, `FloatV4SwapRouter`, …).
 * @dev `changeStrategyAsset` updates the liquid asset key and forwards to `FloatStrategyV4.changeAsset`.
 *      Pool identity (`fee`, `tickSpacing`, `hooks`) comes from strategy configuration — not looked up here.
 *      Does not call `FloatV4SwapRouter` (no stored asset; swaps are per `tokenIn`).
 */
contract FloatContractManagerV4 is Ownable {
    mapping(string => address) public addresses;

    event AddressSet(string indexed name, address indexed contractAddress);
    event AddressDeleted(string indexed name);
    event AddressUpdated(string indexed name, address indexed oldAddress, address indexed newAddress);

    constructor() Ownable(msg.sender) {}

    function setAddress(string memory _name, address _address) public payable onlyOwner {
        require(_address != address(0), "Cannot set zero address");

        address oldAddress = addresses[_name];
        addresses[_name] = _address;
        emit AddressSet(_name, _address);
        if (oldAddress != address(0) && oldAddress != _address) {
            emit AddressUpdated(_name, oldAddress, _address);
        }
    }

    function getAddress(string memory _name) public view returns (address) {
        return addresses[_name];
    }

    function isAddressSet(string memory _name) public view returns (bool) {
        return addresses[_name] != address(0);
    }

    function getAddresses(string[] memory _names) public view returns (address[] memory) {
        address[] memory result = new address[](_names.length);
        for (uint256 i = 0; i < _names.length; i++) {
            result[i] = addresses[_names[i]];
        }
        return result;
    }

    function setAddresses(string[] memory _names, address[] memory _addresses) external payable onlyOwner {
        require(_names.length == _addresses.length, "Arrays length mismatch");
        require(_names.length > 0, "Arrays cannot be empty");
        require(_names.length <= 10, "Too many addresses (max 10)");

        for (uint256 i = 0; i < _names.length; i++) {
            setAddress(_names[i], _addresses[i]);
        }
    }

    function deleteAddress(string memory _name) external payable onlyOwner {
        addresses[_name] = address(0);
        emit AddressDeleted(_name);
    }

    address private constant baseWETH = 0x4200000000000000000000000000000000000006;

    /// @notice Rotates strategy asset and v4 pool tier for the v4 stack; syncs vault.
    /// @param poolFeePips Uniswap v4 pool `fee` (hundredths of a bip) for ASSET/WETH.
    /// @param tickSpacing Must match the pool initialized for that fee/hooks pair.
    /// @param hooks Pool hooks, or `address(0)`.
    function changeStrategyAsset(address _newAssetAddr, uint24 poolFeePips, int24 tickSpacing, address hooks) external {
        address demeterAddr = addresses["Demeter"];
        require(owner() == _msgSender() || demeterAddr == _msgSender(), "Unauthorized");

        require(_newAssetAddr != address(0), "New asset address not set");
        require(_newAssetAddr != baseWETH, "WETH cannot be strategy asset");

        address vaultAddr = addresses["FloatVaultV4"];
        address strategyAddr = addresses["FloatStrategyV4"];

        require(strategyAddr != address(0), "Strategy address not set");

        (bool success,) = strategyAddr.call(
            abi.encodeWithSignature("changeAsset(address,uint24,int24,address)", _newAssetAddr, poolFeePips, tickSpacing, hooks)
        );
        require(success, "changeAsset call failed");

        addresses["ASSET"] = _newAssetAddr;

        if (vaultAddr != address(0)) {
            (bool ok,) = vaultAddr.call(abi.encodeWithSignature("updateAsset()"));
            require(ok, "Vault updateAsset failed");
        }
    }
}
