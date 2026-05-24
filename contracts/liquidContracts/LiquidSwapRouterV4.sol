// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import "./LiquidV4SwapCore.sol";
import "./interfaces/ILiquidV4SwapRouter.sol";

/// @title LiquidSwapRouterV4
/// @notice Slim deployable v4 swap router for the liquid stack (strict quoter path only).
contract LiquidSwapRouterV4 is ILiquidV4SwapRouter, LiquidV4SwapCore, Ownable, ReentrancyGuard {
    address public strategy;
    address public vaultAddr;
    address public tritonAddr;
    bool public initialized;

    error RouterUnauthorized();
    error RouterNotInitialized();

    event ContractSetUp(address indexed caller);
    event StrategySet(address indexed strategy);

    modifier onlyRouterCaller() {
        if (!initialized) revert RouterNotInitialized();
        address s = _msgSender();
        if (s != strategy && s != vaultAddr && s != tritonAddr && s != owner()) revert RouterUnauthorized();
        _;
    }

    constructor() Ownable(_msgSender()) {}

    /// @dev Shared vault/Triton/strategy wiring for `setUpContract` / `setUpRouter`.
    function _wireRouter(address _strategy, address _vault, address _triton) internal {
        require(_strategy != address(0), "strategy=0");
        require(_vault != address(0), "vault=0");
        strategy = _strategy;
        vaultAddr = _vault;
        tritonAddr = _triton;
        initialized = true;
        emit ContractSetUp(_msgSender());
        emit StrategySet(_strategy);
    }

    /// @notice Wire vault/Triton for a standalone router (strategy is an external contract).
    function setUpRouter(address _strategy, address _vault, address _triton) external onlyOwner {
        _wireRouter(_strategy, _vault, _triton);
    }

    /// @notice Alias of `setUpRouter` for standalone `LiquidSwapRouterV4` deployments.
    function setUpContract(address _strategy, address _vault, address _triton) external onlyOwner {
        _wireRouter(_strategy, _vault, _triton);
    }

    function setV4PoolConfig(address assetAddress, PoolKey calldata key, bytes calldata hookData)
        external
        virtual
        override
        onlyOwner
    {
        _setV4PoolConfig(assetAddress, key, hookData);
    }

    function getV4PoolConfig(address assetAddress)
        external
        view
        virtual
        override
        returns (PoolKey memory key, bytes memory hookData)
    {
        return _getV4PoolConfig(assetAddress);
    }

    function swapExactInputSingleStrict(
        address assetAddress,
        bool zeroForOne,
        uint128 amountIn
    ) external override onlyRouterCaller nonReentrant returns (uint256 amountOut) {
        address caller = _msgSender();
        return _swapExactInputSingleStrict(assetAddress, zeroForOne, amountIn, caller, caller);
    }
}
