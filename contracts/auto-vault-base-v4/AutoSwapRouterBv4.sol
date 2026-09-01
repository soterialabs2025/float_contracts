// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import "../v4/V4Deployments8453.sol";
import "./interfaces/IAutoSwapRouterBv4.sol";

/// @title AutoSwapRouterBv4
/// @notice Base (8453) v4 swap router for Auto strategies. Pool keys are owned by strategies and passed per call.
/// @dev Slippage is caller-supplied (`minAmountOut`). The router deliberately does not derive a bound from an
///      in-transaction quote: a quote read from the pool being swapped against reflects any manipulation already
///      applied in the same transaction, so it cannot constrain the execution price.
contract AutoSwapRouterBv4 is IAutoSwapRouterBv4, IUnlockCallback, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager = IPoolManager(V4Deployments8453.POOL_MANAGER);

    /// @notice Cap on this swap's own price movement, measured in sqrtPriceX96 space.
    /// @dev Because price is the square of sqrtPrice, a bound of `n` bps here permits roughly `2n` bps of price
    ///      movement. The default 200 therefore allows about 4% of price impact.
    uint16 public maxPriceImpactBps = 200;

    address public strategyFactory;
    mapping(address => bool) public isAuthorizedStrategy;

    error Unauthorized();
    error NotAuthorized();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroMinOut();
    error Expired();
    error InsufficientOutput();
    error AlreadyAuthorized();
    error BadSlippage();

    event StrategyFactoryUpdated(address indexed factory);
    event StrategyAuthorized(address indexed strategy);
    event StrategyDeauthorized(address indexed strategy);
    event MaxPriceImpactUpdated(uint16 bps);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event SwapExecuted(
        address indexed caller, address indexed recipient, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut
    );

    constructor() Ownable(msg.sender) {}

    modifier onlyAuthorized() {
        if (!isAuthorizedStrategy[msg.sender] && msg.sender != owner()) revert Unauthorized();
        _;
    }

    modifier onlyOwnerOrFactory() {
        if (msg.sender != owner() && msg.sender != strategyFactory) revert Unauthorized();
        _;
    }

    function setStrategyFactory(address factory) external onlyOwner {
        strategyFactory = factory;
        emit StrategyFactoryUpdated(factory);
    }

    function addAuthorizedStrategy(address strategy) external override onlyOwnerOrFactory {
        if (strategy == address(0)) revert ZeroAddress();
        if (isAuthorizedStrategy[strategy]) revert AlreadyAuthorized();
        isAuthorizedStrategy[strategy] = true;
        emit StrategyAuthorized(strategy);
    }

    function removeAuthorizedStrategy(address strategy) external onlyOwner {
        if (!isAuthorizedStrategy[strategy]) revert NotAuthorized();
        delete isAuthorizedStrategy[strategy];
        emit StrategyDeauthorized(strategy);
    }

    /// @param bps Bound in sqrtPrice space; see `maxPriceImpactBps` for the factor-of-two relationship to price.
    function setMaxPriceImpactBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > 5_000) revert BadSlippage();
        maxPriceImpactBps = bps;
        emit MaxPriceImpactUpdated(bps);
    }

    /// @notice Recover tokens or ETH stranded outside a swap. The router holds no balance between transactions.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert ZeroAmount();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Rescued(token, to, amount);
    }

    function swapExactInputSingleStrict(
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        uint256 deadline,
        AutoPoolKey calldata libKey,
        bytes calldata hookData
    ) external override onlyAuthorized nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        // A zero floor would leave the swap wholly unprotected; callers that cannot price must not swap.
        if (minAmountOut == 0) revert ZeroMinOut();
        if (deadline != 0 && block.timestamp > deadline) revert Expired();
        PoolKey memory key = _toCoreKey(libKey);

        PoolId poolId = PoolIdLibrary.toId(key);
        (uint160 sqrtBefore,,,) = StateLibrary.getSlot0(poolManager, poolId);
        require(sqrtBefore != 0, "pool !init");

        amountOut = _swapV4Direct(
            key,
            zeroForOne,
            amountIn,
            minAmountOut,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            hookData,
            msg.sender
        );

        (uint160 sqrtAfter,,,) = StateLibrary.getSlot0(poolManager, poolId);
        _requirePriceImpactBound(sqrtBefore, sqrtAfter, zeroForOne);
    }

    function _toCoreKey(AutoPoolKey calldata k) private pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(k.currency0),
            currency1: Currency.wrap(k.currency1),
            fee: k.fee,
            tickSpacing: k.tickSpacing,
            hooks: IHooks(k.hooks)
        });
    }

    function _swapV4Direct(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        uint160 sqrtPriceLimitX96,
        bytes memory hookData,
        address recipient
    ) private returns (uint256 amountOut) {
        address tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        address tokenOut = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        bytes memory data = abi.encode(
            recipient, key, zeroForOne, int256(uint256(amountIn)), sqrtPriceLimitX96, hookData
        );

        amountOut = abi.decode(poolManager.unlock(data), (uint256));
        if (amountOut < minAmountOut) revert InsufficientOutput();
        emit SwapExecuted(msg.sender, recipient, tokenIn, tokenOut, amountIn, amountOut);
    }

    function _requirePriceImpactBound(uint160 sqrtBefore, uint160 sqrtAfter, bool zeroForOne) internal view {
        uint256 diff = zeroForOne
            ? (sqrtBefore > sqrtAfter ? uint256(sqrtBefore - sqrtAfter) : 0)
            : (sqrtAfter > sqrtBefore ? uint256(sqrtAfter - sqrtBefore) : 0);
        uint256 bps = (diff * 10_000) / uint256(sqrtBefore);
        require(bps <= uint256(maxPriceImpactBps), "price impact");
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "only PM");
        (
            address recipient,
            PoolKey memory key,
            bool zeroForOne,
            int256 amountIn,
            uint160 sqrtPriceLimitX96,
            bytes memory hookData
        ) = abi.decode(data, (address, PoolKey, bool, int256, uint160, bytes));

        Currency inC = zeroForOne ? key.currency0 : key.currency1;
        Currency outC = zeroForOne ? key.currency1 : key.currency0;

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -amountIn, sqrtPriceLimitX96: sqrtPriceLimitX96}),
            hookData
        );

        int128 deltaIn = zeroForOne ? delta.amount0() : delta.amount1();
        int128 deltaOut = zeroForOne ? delta.amount1() : delta.amount0();
        require(deltaIn <= 0 && deltaOut >= 0, "delta");

        uint256 owed = uint256(uint128(-deltaIn));
        uint256 received = uint256(uint128(deltaOut));

        poolManager.sync(inC);
        IERC20(Currency.unwrap(inC)).safeTransfer(address(poolManager), owed);
        poolManager.settle();
        poolManager.take(outC, recipient, received);

        // Partial fills leave input behind. Refund this swap's own residue only, never the whole balance.
        uint256 residue = uint256(amountIn) - owed;
        if (residue > 0) IERC20(Currency.unwrap(inC)).safeTransfer(recipient, residue);

        return abi.encode(received);
    }
}
