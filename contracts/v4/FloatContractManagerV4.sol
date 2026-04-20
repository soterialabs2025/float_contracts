// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../../interfaces/IUniswapV3Factory.sol";

/**
 * @title FloatContractManagerV4
 * @notice Registry for v4 stack deployments (`FloatVaultV4`, `FloatStrategyV4`, `FloatV4SwapRouter`, …).
 * @dev `changeStrategyAsset` mirrors `FloatContractManager` but targets v4 manager keys. Optional v3 pool
 *      address is stored under `AssetPoolV3` for tooling; the v4 strategy ignores it when rebuilding `poolKey`.
 *      Does not call `FloatV4SwapRouter` (no stored asset; swaps are per `tokenIn`).
 */
contract FloatContractManagerV4 is Ownable {
    address private constant v3FactoryAddr = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address private constant baseWETH = 0x4200000000000000000000000000000000000006;
    uint24 private constant V3_FEE = 10_000;

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

    /// @notice Rotates strategy asset for the v4 stack and syncs vault + optional swap router.
    function changeStrategyAsset(address _newAssetAddr) external {
        address demeterAddr = addresses["Demeter"];
        require(owner() == _msgSender() || demeterAddr == _msgSender(), "Unauthorized");

        require(_newAssetAddr != address(0), "New asset address not set");
        require(_newAssetAddr != baseWETH, "WETH cannot be strategy asset");

        address vaultAddr = addresses["FloatVaultV4"];
        address strategyAddr = addresses["FloatStrategyV4"];

        require(strategyAddr != address(0), "Strategy address not set");

        address newPoolV3Addr = IUniswapV3Factory(v3FactoryAddr).getPool(_newAssetAddr, baseWETH, V3_FEE);
        if (newPoolV3Addr == address(0)) {
            newPoolV3Addr = IUniswapV3Factory(v3FactoryAddr).getPool(baseWETH, _newAssetAddr, V3_FEE);
        }
        require(newPoolV3Addr != address(0), "Pool does not exist for asset/WETH");

        (bool success,) =
            strategyAddr.call(abi.encodeWithSignature("changeAsset(address,address)", _newAssetAddr, newPoolV3Addr));
        require(success, "changeAsset call failed");

        addresses["LiquidASSET"] = _newAssetAddr;
        addresses["AssetPoolV3"] = newPoolV3Addr;

        if (vaultAddr != address(0)) {
            (bool ok,) = vaultAddr.call(abi.encodeWithSignature("updateAsset()"));
            require(ok, "Vault updateAsset failed");
        }
    }
}
