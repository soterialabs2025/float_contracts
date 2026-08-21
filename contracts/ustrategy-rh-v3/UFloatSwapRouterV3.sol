// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./V3Deployments4663.sol";
import "./interfaces/IUFloatV3StrategySwapRouter.sol";
import "./interfaces/IQuoterV2.sol";
import "./interfaces/IUniswapRouter.sol";
import "./interfaces/IUniswapV3Factory.sol";

/// @title UFloatSwapRouterV3
/// @notice Robinhood Uniswap V3 swap router for UFloatStrategyV3. Per-asset fee registry (no PoolKey).
contract UFloatSwapRouterV3 is IUFloatV3StrategySwapRouter, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapRouter public immutable router = IUniswapRouter(V3Deployments4663.SWAP_ROUTER02);
    IQuoterV2 public immutable quoter = IQuoterV2(V3Deployments4663.QUOTER_V2);
    IUniswapV3Factory public immutable v3Factory = IUniswapV3Factory(V3Deployments4663.FACTORY);
    address public immutable weth = V3Deployments4663.WETH;

    uint16 public strictStrategySlippageBps = 200;
    address public strategyFactory;

    mapping(address => uint24) private _poolFee;
    mapping(address => bool) private _hasConfig;
    address[] private _registeredAssets;
    mapping(address => uint256) private _registeredAssetIndex;

    mapping(address => bool) public isAuthorizedStrategy;
    address[] private _authorizedStrategies;
    mapping(address => uint256) private _authorizedStrategyIndex;

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error AlreadyAuthorized();
    error NotAuthorized();
    error InvalidSlippage();
    error PoolMissing();
    error CannotRegisterWeth();
    error AssetNotRegistered();

    event StrategyFactoryUpdated(address indexed factory);
    event StrategyAuthorized(address indexed strategy);
    event StrategyDeauthorized(address indexed strategy);
    event StrictStrategySlippageUpdated(uint16 bps);
    event PoolConfigSet(address indexed asset, uint24 fee);
    event PoolConfigRemoved(address indexed asset);
    event SwapExecuted(
        address indexed strategy, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut
    );

    constructor() Ownable(msg.sender) {}

    modifier onlyOwnerOrFactory() {
        if (msg.sender != owner() && msg.sender != strategyFactory) revert Unauthorized();
        _;
    }

    function setStrategyFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        strategyFactory = factory_;
        emit StrategyFactoryUpdated(factory_);
    }

    function setStrictStrategySlippageBps(uint16 bps) external onlyOwner {
        if (bps > 10_000) revert InvalidSlippage();
        strictStrategySlippageBps = bps;
        emit StrictStrategySlippageUpdated(bps);
    }

    function setPoolConfig(address asset, uint24 fee) external onlyOwner {
        _setPoolConfig(asset, fee);
    }

    /// @dev Returns true if config was set (pool exists); false if pool missing.
    function trySetPoolConfig(address asset, uint24 fee) external onlyOwner returns (bool) {
        if (asset == address(0) || asset == weth) return false;
        if (v3Factory.getPool(asset, weth, fee) == address(0)) return false;
        _setPoolConfig(asset, fee);
        return true;
    }

    function _setPoolConfig(address asset, uint24 fee) internal {
        if (asset == address(0)) revert ZeroAddress();
        if (asset == weth) revert CannotRegisterWeth();
        if (v3Factory.getPool(asset, weth, fee) == address(0)) revert PoolMissing();
        _poolFee[asset] = fee;
        if (!_hasConfig[asset]) {
            _hasConfig[asset] = true;
            _registeredAssets.push(asset);
            _registeredAssetIndex[asset] = _registeredAssets.length;
        }
        emit PoolConfigSet(asset, fee);
    }

    function removePoolConfig(address asset) external onlyOwner {
        if (!_hasConfig[asset]) revert AssetNotRegistered();
        uint256 idx = _registeredAssetIndex[asset];
        uint256 last = _registeredAssets.length;
        if (idx != last) {
            address moved = _registeredAssets[last - 1];
            _registeredAssets[idx - 1] = moved;
            _registeredAssetIndex[moved] = idx;
        }
        _registeredAssets.pop();
        delete _registeredAssetIndex[asset];
        delete _hasConfig[asset];
        delete _poolFee[asset];
        emit PoolConfigRemoved(asset);
    }

    function hasPoolConfig(address asset) external view override returns (bool) {
        return _hasConfig[asset];
    }

    function getPoolConfig(address asset) external view override returns (uint24 fee) {
        if (!_hasConfig[asset]) revert AssetNotRegistered();
        return _poolFee[asset];
    }

    function getRegisteredAssets() external view returns (address[] memory) {
        return _registeredAssets;
    }

    function registeredAssetCount() external view returns (uint256) {
        return _registeredAssets.length;
    }

    function addAuthorizedStrategy(address strategy) external override onlyOwnerOrFactory {
        if (strategy == address(0)) revert ZeroAddress();
        if (isAuthorizedStrategy[strategy]) revert AlreadyAuthorized();
        isAuthorizedStrategy[strategy] = true;
        _authorizedStrategies.push(strategy);
        _authorizedStrategyIndex[strategy] = _authorizedStrategies.length;
        emit StrategyAuthorized(strategy);
    }

    function removeAuthorizedStrategy(address strategy) external onlyOwner {
        if (!isAuthorizedStrategy[strategy]) revert NotAuthorized();
        uint256 idx = _authorizedStrategyIndex[strategy];
        uint256 last = _authorizedStrategies.length;
        if (idx != last) {
            address moved = _authorizedStrategies[last - 1];
            _authorizedStrategies[idx - 1] = moved;
            _authorizedStrategyIndex[moved] = idx;
        }
        _authorizedStrategies.pop();
        delete _authorizedStrategyIndex[strategy];
        delete isAuthorizedStrategy[strategy];
        emit StrategyDeauthorized(strategy);
    }

    function getAuthorizedStrategies() external view returns (address[] memory) {
        return _authorizedStrategies;
    }

    function swapExactInputSingleStrict(address tokenIn, address tokenOut, uint24 fee, uint128 amountIn)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (!isAuthorizedStrategy[msg.sender]) revert Unauthorized();
        if (amountIn == 0) revert ZeroAmount();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 quoted;
        try quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: fee, sqrtPriceLimitX96: 0
            })
        ) returns (uint256 amountOut_, uint160, uint32, uint256) {
            quoted = amountOut_;
        } catch {
            revert("quoter failed");
        }
        if (quoted == 0) revert ZeroAmount();
        uint256 minOut = Math.mulDiv(quoted, 10_000 - strictStrategySlippageBps, 10_000);

        IERC20(tokenIn).forceApprove(address(router), amountIn);
        amountOut = router.exactInputSingle(
            IUniswapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: msg.sender,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }
}
