// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./libraries/LiquidityLibraryV5.sol";
import "./interfaces/IFloatStrategyV4.sol";
import "./interfaces/IFloatV4StrategySwapRouter.sol";
import "./V4Deployments8453.sol";

/**
 * @title FloatContractManagerV4
 * @author TB_Contracts Team (v4 stack)
 * @notice Central registry for v4 protocol contract addresses — same role as `FloatContractManager` for v3.
 * @dev Single source of truth for names → addresses (`FloatVaultV4`, `FloatStrategyV4`, `FloatSwapRouterV4`, …).
 *      `changeStrategyAsset(asset)` rotates ASSET; `exitStrategyToStable()` exits to WETH / mode STABLE.
 *      PoolKeys live in
 *      `FloatSwapRouterV4.v4PoolConfig` (seeded at deploy via `_seedV4PoolConfigs`, extended via
 *      `setV4PoolConfig`). The manager pulls the key from the router, validates ASSET/WETH layout, calls
 *      `IFloatStrategyV4.changeAsset(asset, key)`, then refreshes the vault's local asset reference via
 *      `updateAsset()`. The frontend never submits a PoolKey.
 * @custom:version 3.0.0
 */
contract FloatContractManagerV4 is Ownable {
    address private constant baseWETH = 0x4200000000000000000000000000000000000006;

    mapping(string => address) public addresses;

    event AddressSet(string indexed name, address indexed contractAddress);
    event AddressDeleted(string indexed name);
    event AddressUpdated(string indexed name, address indexed oldAddress, address indexed newAddress);

    constructor() Ownable(msg.sender) {}

    modifier onlyOwnerOrDemeter() {
        address demeterAddr = addresses["Demeter"];
        require(owner() == _msgSender() || demeterAddr == _msgSender(), "Unauthorized");
        _;
    }

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

    /// @notice Rotate the v4 strategy's ASSET to one of the assets pre-registered with `FloatSwapRouterV4`.
    /// @dev    Single source of truth: the PoolKey is read from `FloatSwapRouterV4.getV4PoolConfig(asset)` (seeded
    ///         at deploy / extended via `setV4PoolConfig`). The frontend supplies only the asset address.
    ///         Flow:
    ///           1. Read `(key, _)` from `FloatSwapRouterV4.getV4PoolConfig(_newAssetAddr)`.
    ///           2. Validate the pulled key is canonical ASSET/WETH (`currency0 < currency1`, one side == WETH,
    ///              the other == `_newAssetAddr`). Catches a misregistered router entry before it reaches the
    ///              strategy.
    ///           3. Call `IFloatStrategyV4.changeAsset(asset, key)` — strategy flattens the OLD pool, swaps to
    ///              WETH, then adopts the NEW `key`. (Strategy reads `hookData` for LP ops directly from the
    ///              router by `address(ASSET)`, before AND after the rotation.)
    ///           4. Update the registry's `"ASSET"` entry and refresh the vault's local asset reference.
    /// @param _newAssetAddr Non-WETH side of the pool — strategy's new ASSET. Must be pre-registered on the router.
    function changeStrategyAsset(address _newAssetAddr) external onlyOwnerOrDemeter {
        require(_newAssetAddr != address(0), "New asset address not set");
        require(_newAssetAddr != baseWETH, "WETH cannot be strategy asset");

        address vaultAddr = addresses["FloatVaultV4"];
        address strategyAddr = addresses["FloatStrategyV4"];
        address swapRouterAddr = addresses["FloatSwapRouterV4"];
        require(strategyAddr != address(0), "Strategy address not set");
        require(swapRouterAddr != address(0), "SwapRouter address not set");

        // 1. Pull the canonical PoolKey from the swap router's pre-seeded registry.
        //    Low-level staticcall so we avoid importing the v4-core `PoolKey` here; the router's
        //    `(Currency, Currency, uint24, int24, IHooks)` struct is wire-compatible with
        //    `LiquidityLibraryV5.PoolKey`'s `(address, address, uint24, int24, address)`.
        (bool ok, bytes memory ret) = swapRouterAddr.staticcall(
            abi.encodeWithSignature("getV4PoolConfig(address)", _newAssetAddr)
        );
        if (!ok) _bubbleRevert(ret, "getV4PoolConfig failed");
        (LiquidityLibraryV5.PoolKey memory key, ) = abi.decode(ret, (LiquidityLibraryV5.PoolKey, bytes));

        // 2. Defense-in-depth validation: the router only enforces `assetAddress in {c0, c1}`, not that the
        //    other side is WETH. The Float strategy assumes ASSET/WETH; reject anything else early.
        require(key.currency0 < key.currency1, "PoolKey: c0>=c1");
        require(
            (key.currency0 == _newAssetAddr && key.currency1 == baseWETH) ||
            (key.currency1 == _newAssetAddr && key.currency0 == baseWETH),
            "PoolKey != ASSET/WETH"
        );

        // 3. Rotate strategy state via typed interface (strategy flattens against the OLD pool first).
        IFloatStrategyV4(strategyAddr).changeAsset(_newAssetAddr, key);

        // 4. Refresh registry + vault local reference.
        addresses["ASSET"] = _newAssetAddr;
        if (vaultAddr != address(0)) {
            (bool ok2, bytes memory ret2) = vaultAddr.call(abi.encodeWithSignature("updateAsset()"));
            if (!ok2) _bubbleRevert(ret2, "Vault updateAsset failed");
        }
    }

    /// @notice Flatten LP, swap to WETH, set strategy `STABLE` (mode 4). Registry `"ASSET"` becomes WETH.
    /// @dev    `key` is unused by the strategy on the WETH exit path; pass an empty struct.
    function exitStrategyToStable() external onlyOwnerOrDemeter {
        address vaultAddr = addresses["FloatVaultV4"];
        address strategyAddr = addresses["FloatStrategyV4"];
        require(strategyAddr != address(0), "Strategy address not set");

        LiquidityLibraryV5.PoolKey memory key;
        IFloatStrategyV4(strategyAddr).changeAsset(baseWETH, key);

        addresses["ASSET"] = baseWETH;
        if (vaultAddr != address(0)) {
            (bool ok, bytes memory ret) = vaultAddr.call(abi.encodeWithSignature("updateAsset()"));
            if (!ok) _bubbleRevert(ret, "Vault updateAsset failed");
        }
    }

    /// @dev Re-throw a low-level call's revert payload (preserves nested `require` strings / custom errors).
    function _bubbleRevert(bytes memory ret, string memory fallbackMsg) private pure {
        if (ret.length > 0) {
            assembly { revert(add(ret, 0x20), mload(ret)) }
        }
        revert(fallbackMsg);
    }
}
