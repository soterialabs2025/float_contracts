// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./V3Deployments4663.sol";
import "./interfaces/IAutoSwapRouterRhV3.sol";
import "./interfaces/IQuoterV2.sol";
import "./interfaces/IUniswapRouter.sol";

contract AutoSwapRouterRhV3 is IAutoSwapRouterRhV3, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapRouter public immutable router = IUniswapRouter(V3Deployments4663.SWAP_ROUTER02);
    IQuoterV2 public immutable quoter = IQuoterV2(V3Deployments4663.QUOTER_V2);
    uint16 public strictStrategySlippageBps = 100;
    address public strategyFactory;
    mapping(address => bool) public isAuthorizedStrategy;

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error AlreadyAuthorized();
    error InvalidSlippage();

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

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 quoted;
        try quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: fee, sqrtPriceLimitX96: 0
            })
        ) returns (
            uint256 amountOut_, uint160, uint32, uint256
        ) {
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
