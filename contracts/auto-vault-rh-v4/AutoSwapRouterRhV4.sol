// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "../../lib/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "../../lib/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "../../lib/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "../../lib/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "../../lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "../../lib/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../../lib/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "../../lib/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "../../lib/v4-core/src/libraries/TickMath.sol";
import {IV4Quoter} from "../../lib/v4-periphery/src/interfaces/IV4Quoter.sol";

import "./V4Deployments4663.sol";
import "./interfaces/IAutoSwapRouterRhV4.sol";

/// @title AutoSwapRouterRhV4
/// @notice RH (4663) v4 swap router for Auto strategies. Pool keys are owned by strategies and passed per call.
contract AutoSwapRouterRhV4 is IAutoSwapRouterRhV4, IUnlockCallback, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager = IPoolManager(V4Deployments4663.POOL_MANAGER);
    IV4Quoter public immutable v4Quoter = IV4Quoter(V4Deployments4663.QUOTER);

    uint16 public strictStrategySlippageBps = 100;
    uint16 public maxPriceImpactBps = 200;

    address public strategyFactory;
    mapping(address => bool) public isAuthorizedStrategy;

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error AlreadyAuthorized();
    error BadSlippage();

    event StrategyFactoryUpdated(address indexed factory);
    event StrategyAuthorized(address indexed strategy);
    event StrictStrategySlippageUpdated(uint16 bps);
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

    function setStrictStrategySlippageBps(uint16 bps) external onlyOwner {
        if (bps > 5_000) revert BadSlippage();
        strictStrategySlippageBps = bps;
        emit StrictStrategySlippageUpdated(bps);
    }

    function swapExactInputSingleStrict(
        bool zeroForOne,
        uint128 amountIn,
        AutoPoolKey calldata libKey,
        bytes calldata hookData
    ) external payable override onlyAuthorized nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        PoolKey memory key = _toCoreKey(libKey);
        address tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        address tokenOut = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert ZeroAmount();
        } else {
            if (msg.value != 0) revert ZeroAmount();
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        PoolId poolId = PoolIdLibrary.toId(key);
        (uint160 sqrtBefore,,,) = StateLibrary.getSlot0(poolManager, poolId);
        require(sqrtBefore != 0, "pool !init");

        uint128 minOut = _minOutFromV4Quoter(key, zeroForOne, amountIn, hookData, strictStrategySlippageBps);
        uint256 balBefore = _bal(tokenOut, msg.sender);
        _swapV4Direct(
            key,
            zeroForOne,
            amountIn,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            hookData,
            msg.sender
        );
        amountOut = _bal(tokenOut, msg.sender) - balBefore;
        require(amountOut >= minOut, "Insufficient output amount");
        emit SwapExecuted(msg.sender, msg.sender, tokenIn, tokenOut, amountIn, amountOut);

        (uint160 sqrtAfter,,,) = StateLibrary.getSlot0(poolManager, poolId);
        _requirePriceImpactBound(sqrtBefore, sqrtAfter, zeroForOne);
    }

    function _bal(address token, address account) private view returns (uint256) {
        return token == address(0) ? account.balance : IERC20(token).balanceOf(account);
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
        uint160 sqrtPriceLimitX96,
        bytes memory hookData,
        address recipient
    ) private {
        bytes memory data = abi.encode(
            recipient, key, zeroForOne, int256(uint256(amountIn)), sqrtPriceLimitX96, hookData
        );
        poolManager.unlock(data);
    }

    function _minOutFromV4Quoter(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        bytes memory hookData,
        uint16 slippageBps
    ) internal returns (uint128 minOut) {
        try v4Quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                exactAmount: amountIn,
                hookData: hookData
            })
        ) returns (uint256 quoted, uint256) {
            require(quoted > 0, "quoter=0");
            minOut = uint128(Math.mulDiv(quoted, 10_000 - uint256(slippageBps), 10_000));
        } catch {
            revert("quoter failed");
        }
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

        if (Currency.unwrap(inC) == address(0)) {
            poolManager.settle{value: owed}();
        } else {
            poolManager.sync(inC);
            IERC20(Currency.unwrap(inC)).safeTransfer(address(poolManager), owed);
            poolManager.settle();
        }
        poolManager.take(outC, recipient, received);
        if (address(this).balance > 0) {
            (bool ok,) = recipient.call{value: address(this).balance}("");
            require(ok, "eth");
        }
        return "";
    }

    receive() external payable {}
}
