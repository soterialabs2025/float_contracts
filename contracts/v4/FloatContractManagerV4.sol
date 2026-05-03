// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

import "../../interfaces/IPoolManagerV4.sol";
import "../../libraries/LiquidityLibraryV4.sol";
import "./V4Deployments8453.sol";

/**
 * @title FloatContractManagerV4
 * @author TB_Contracts Team (v4 stack)
 * @notice Central registry for v4 protocol contract addresses — same role as `FloatContractManager` for v3.
 * @dev Single source of truth for names → addresses (`FloatVaultV4`, `FloatStrategyV4`, `FloatSwapRouterV4`, …).
 *      `changeStrategyAsset(address)` resolves a vanilla (no-hooks) ASSET/WETH v4 pool on Base `PoolManager` by fee
 *      tier, analogous to `_poolV3ForAsset` + `changeStrategyAsset` on v3. Explicit `fee` / `tickSpacing` / `hooks`
 *      remain available when discovery is wrong or the pool uses custom hooks.
 *      Does not call `FloatSwapRouterV4` (no stored asset; swaps are per `tokenIn`).
 * @custom:version 1.0.0
 */
contract FloatContractManagerV4 is Ownable {
    address private constant baseWETH = 0x4200000000000000000000000000000000000006;
    /// @dev Base canonical USDC — discovery tries 0.05% first (common Base v4 WETH/USDC tier).
    address private constant baseUSDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

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

    function _feeToTickSpacingV4(uint24 fee) private pure returns (int24) {
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10_000) return 200;
        revert("fee tier");
    }

    /**
     * @notice Same responsibility as v3 `_poolV3ForAsset`: find ASSET/WETH liquidity for the strategy.
     * @dev Probes standard Uniswap v4 fee tiers on Base `V4Deployments8453.POOL_MANAGER` with `hooks = address(0)`.
     *      Initialized pool ⇒ `getSlot0` returns non-zero `sqrtPriceX96`. USDC prefers 500 (0.05%) first on Base
     *      (see e.g. GeckoTerminal WETH/USDC v4 primary tier), then 3000 → 10000;
     *      other assets prefer 10000 (v3 manager default) → 3000 → 500.
     */
    function _resolveV4PoolParamsForAsset(address asset) private view returns (uint24 fee, int24 tickSpacing, address hooks) {
        require(asset != address(0) && asset != baseWETH, "bad asset");
        hooks = address(0);
        address weth = baseWETH;
        address c0 = asset < weth ? asset : weth;
        address c1 = asset < weth ? weth : asset;

        uint24[3] memory fees = asset == baseUSDC
            ? [uint24(500), uint24(3000), uint24(10_000)]
            : [uint24(10_000), uint24(3000), uint24(500)];

        IPoolManagerV4 pm = IPoolManagerV4(V4Deployments8453.POOL_MANAGER);

        for (uint256 i = 0; i < fees.length; i++) {
            int24 ts = _feeToTickSpacingV4(fees[i]);
            LiquidityLibraryV4.PoolKey memory key = LiquidityLibraryV4.PoolKey({
                currency0: c0,
                currency1: c1,
                fee: fees[i],
                tickSpacing: ts,
                hooks: hooks
            });
            (uint160 sqrtPriceX96,,,) = pm.getSlot0(LiquidityLibraryV4.poolId(key));
            if (sqrtPriceX96 != 0) {
                return (fees[i], ts, hooks);
            }
        }
        revert("Pool does not exist for asset/WETH");
    }

    /// @notice Read-only helper: which vanilla v4 tier resolves for `asset`/WETH on Base.
    function getV4PoolParamsForAsset(address asset) external view returns (uint24 fee, int24 tickSpacing, address hooks) {
        return _resolveV4PoolParamsForAsset(asset);
    }

    /// @notice Same as four-arg overload, but discovers `(fee, tickSpacing, hooks)` like v3 manager + `_poolV3ForAsset`.
    function changeStrategyAsset(address _newAssetAddr) external onlyOwnerOrDemeter {
        require(_newAssetAddr != address(0), "New asset address not set");
        require(_newAssetAddr != baseWETH, "WETH cannot be strategy asset");
        (uint24 f, int24 ts, address h) = _resolveV4PoolParamsForAsset(_newAssetAddr);
        _changeStrategyAsset(_newAssetAddr, f, ts, h);
    }

    /// @notice Rotates strategy asset and v4 pool tier for the v4 stack; syncs vault.
    /// @param poolFeePips Uniswap v4 pool `fee` (hundredths of a bip) for ASSET/WETH.
    /// @param tickSpacing Must match the pool initialized for that fee/hooks pair.
    /// @param hooks Pool hooks, or `address(0)`.
    function changeStrategyAsset(address _newAssetAddr, uint24 poolFeePips, int24 tickSpacing, address hooks)
        external
        onlyOwnerOrDemeter
    {
        require(_newAssetAddr != address(0), "New asset address not set");
        require(_newAssetAddr != baseWETH, "WETH cannot be strategy asset");
        _changeStrategyAsset(_newAssetAddr, poolFeePips, tickSpacing, hooks);
    }

    function _changeStrategyAsset(address _newAssetAddr, uint24 poolFeePips, int24 tickSpacing, address hooks) private {
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
