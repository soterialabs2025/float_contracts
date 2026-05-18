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
    address public demeterAddr;
    bool public initialized;

    error RouterUnauthorized();
    error RouterNotInitialized();

    event ContractSetUp(address indexed caller);
    event StrategySet(address indexed strategy);

    modifier onlyRouterCaller() {
        if (!initialized) revert RouterNotInitialized();
        address s = _msgSender();
        if (s != strategy && s != vaultAddr && s != demeterAddr && s != owner()) revert RouterUnauthorized();
        _;
    }

    constructor() Ownable(_msgSender()) {}

    /// @notice Wire authorized callers (strategy / vault / demeter).
    function setUpContract(address _strategy, address _vault, address _demeter) external onlyOwner {
        require(_strategy != address(0), "strategy=0");
        strategy = _strategy;
        vaultAddr = _vault;
        demeterAddr = _demeter;
        initialized = true;
        emit ContractSetUp(_msgSender());
        emit StrategySet(_strategy);
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
