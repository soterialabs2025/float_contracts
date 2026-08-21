// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./SushiV3Deployments4663.sol";
import "./interfaces/IAutoSwapRouterSv3.sol";
import "./interfaces/IQuoterV2.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./interfaces/IUniswapV3PoolMinimal.sol";
import "./interfaces/IUniswapV3SwapCallback.sol";

/// @notice Authorized single-hop Sushi V3 swaps via Quoter + pool.swap (no RedSnwapper / SwapRouter02).
contract AutoSwapRouterSv3 is IAutoSwapRouterSv3, IUniswapV3SwapCallback, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Uni V3 TickMath bounds (avoid relying on library `internal` constant visibility).
    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    IUniswapV3Factory public immutable factory = IUniswapV3Factory(SushiV3Deployments4663.FACTORY);
    IQuoterV2 public immutable quoter = IQuoterV2(SushiV3Deployments4663.QUOTER);
    uint16 public strictStrategySlippageBps = 100;
    address public strategyFactory;
    mapping(address => bool) public isAuthorizedStrategy;

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error AlreadyAuthorized();
    error InvalidSlippage();
    error InvalidPool();
    error InsufficientOutput();

    event StrategyFactoryUpdated(address indexed factory);
    event StrategyAuthorized(address indexed strategy);
    event StrictStrategySlippageUpdated(uint16 bps);
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

    function addAuthorizedStrategy(address strategy) external override onlyOwnerOrFactory {
        if (strategy == address(0)) revert ZeroAddress();
        if (isAuthorizedStrategy[strategy]) revert AlreadyAuthorized();
        isAuthorizedStrategy[strategy] = true;
        emit StrategyAuthorized(strategy);
    }

    function swapExactInputSingleStrict(address tokenIn, address tokenOut, uint24 fee, uint128 amountIn)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (!isAuthorizedStrategy[msg.sender]) revert Unauthorized();
        if (amountIn == 0) revert ZeroAmount();

        address pool = factory.getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) revert InvalidPool();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 quoted;
        try quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                fee: fee,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 amountOut_, uint160, uint32, uint256) {
            quoted = amountOut_;
        } catch {
            revert("quoter failed");
        }
        if (quoted == 0) revert ZeroAmount();
        uint256 minOut = Math.mulDiv(quoted, 10_000 - strictStrategySlippageBps, 10_000);

        bool zeroForOne = tokenIn < tokenOut;
        uint160 limit = zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;

        uint256 balOutBefore = IERC20(tokenOut).balanceOf(msg.sender);
        IUniswapV3PoolMinimal(pool).swap(
            msg.sender,
            zeroForOne,
            int256(uint256(amountIn)),
            limit,
            abi.encode(msg.sender, tokenIn, tokenOut, fee)
        );
        amountOut = IERC20(tokenOut).balanceOf(msg.sender) - balOutBefore;
        if (amountOut < minOut) revert InsufficientOutput();

        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        (address payer, address tokenIn, address tokenOut, uint24 fee) =
            abi.decode(data, (address, address, address, uint24));
        address expectedPool = factory.getPool(tokenIn, tokenOut, fee);
        if (msg.sender != expectedPool) revert InvalidPool();

        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        // Tokens were pulled from the strategy into this router before swap.
        IERC20(tokenIn).safeTransfer(msg.sender, amountToPay);
        // Silence unused (callback always pays tokenIn for exact-input).
        payer;
    }
}
