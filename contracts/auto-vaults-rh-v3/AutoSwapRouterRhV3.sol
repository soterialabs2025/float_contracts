// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./V3Deployments4663.sol";
import "./libraries/TickMath.sol";
import "./interfaces/IAutoSwapRouterRhV3.sol";
import "./interfaces/IUniswapRouter.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./interfaces/IUniswapV3PoolMinimal.sol";

/// @title AutoSwapRouterRhV3
/// @notice Robinhood Chain (4663) Uniswap v3 swap router for Auto strategies.
/// @dev Caller supplies `maxDevBps` and `slipBps`. Floor is TWAP-gated spot.
contract AutoSwapRouterRhV3 is IAutoSwapRouterRhV3, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant DIVISOR = 10_000;

    IUniswapRouter public immutable router = IUniswapRouter(V3Deployments4663.SWAP_ROUTER02);
    IUniswapV3Factory public immutable factory = IUniswapV3Factory(V3Deployments4663.FACTORY);

    /// @notice Oracle window used to admit the swap. `0` is rejected rather than treated as "no gate".
    uint32 public twapSeconds = 30 minutes;
    address public strategyFactory;
    mapping(address => bool) public isAuthorizedStrategy;

    error Unauthorized();
    error NotAuthorized();
    error ZeroAddress();
    error ZeroAmount();
    error AlreadyAuthorized();
    error InvalidSlippage();
    error InvalidPool();
    error Expired();
    error OracleUnavailable();
    error PriceOutOfBand();

    event StrategyFactoryUpdated(address indexed factory);
    event StrategyAuthorized(address indexed strategy);
    event StrategyDeauthorized(address indexed strategy);
    event TwapSecondsUpdated(uint32 secs);
    event Rescued(address indexed token, address indexed to, uint256 amount);
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

    function setTwapSeconds(uint32 secs) external onlyOwner {
        if (secs < 60 || secs > 1 days) revert InvalidSlippage();
        twapSeconds = secs;
        emit TwapSecondsUpdated(secs);
    }

    function addAuthorizedStrategy(address strategy) external override onlyOwnerOrFactory {
        if (strategy == address(0)) revert ZeroAddress();
        if (isAuthorizedStrategy[strategy]) revert AlreadyAuthorized();
        isAuthorizedStrategy[strategy] = true;
        emit StrategyAuthorized(strategy);
    }

    function removeAuthorizedStrategy(address strategy) external override onlyOwner {
        if (!isAuthorizedStrategy[strategy]) revert NotAuthorized();
        delete isAuthorizedStrategy[strategy];
        emit StrategyDeauthorized(strategy);
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
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint128 amountIn,
        uint256 maxDevBps,
        uint256 slipBps,
        uint256 deadline
    ) external override nonReentrant returns (uint256 amountOut) {
        if (!isAuthorizedStrategy[msg.sender]) revert Unauthorized();
        if (amountIn == 0) revert ZeroAmount();
        if (deadline != 0 && block.timestamp > deadline) revert Expired();

        address pool = factory.getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) revert InvalidPool();
        uint256 minOut = _minOut(pool, tokenIn, amountIn, fee, maxDevBps, slipBps);
        if (minOut == 0) revert ZeroAmount();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
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

    /// @dev TWAP-admitted spot floor. Reverts if unpriceable.
    function _minOut(address pool, address tokenIn, uint128 amountIn, uint24 fee, uint256 maxDevBps, uint256 slipBps)
        internal
        view
        returns (uint256)
    {
        if (slipBps > 1_000) revert InvalidSlippage();
        bool baseIsToken0 = tokenIn == IUniswapV3PoolMinimal(pool).token0();
        uint160 twapSqrt = _twapSqrt(pool);
        if (twapSqrt == 0) revert OracleUnavailable();
        (uint160 spotSqrt,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();

        uint256 twap = _quoteAtSqrt(twapSqrt, 1e18, baseIsToken0);
        uint256 spot = _quoteAtSqrt(spotSqrt, 1e18, baseIsToken0);
        if (twap == 0 || spot == 0) revert OracleUnavailable();
        uint256 hi = spot > twap ? spot : twap;
        uint256 lo = spot > twap ? twap : spot;
        if (Math.mulDiv(hi - lo, DIVISOR, twap) > maxDevBps) revert PriceOutOfBand();

        uint256 quote = _quoteAtSqrt(spotSqrt, amountIn, baseIsToken0);
        if (quote == 0) revert ZeroAmount();
        // Fee tiers are hundredths of a bip, so /100 puts `fee` in bps alongside the tolerance.
        uint256 afterPoolFee = Math.mulDiv(quote, DIVISOR - uint256(fee) / 100, DIVISOR);
        return Math.mulDiv(afterPoolFee, DIVISOR - slipBps, DIVISOR);
    }

    /// @dev Arithmetic-mean-tick TWAP as sqrtPriceX96. Zero if the oracle cannot serve the window.
    function _twapSqrt(address pool) internal view returns (uint160) {
        uint32 period = twapSeconds;
        if (period == 0) return 0;
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = period;
        secondsAgos[1] = 0;
        try IUniswapV3PoolMinimal(pool).observe(secondsAgos) returns (int56[] memory tc, uint160[] memory) {
            int56 delta = tc[1] - tc[0];
            int56 periodI = int56(uint56(period));
            int24 meanTick = int24(delta / periodI);
            if (delta < 0 && (delta % periodI != 0)) meanTick--;
            return TickMath.getSqrtRatioAtTick(meanTick);
        } catch {
            return 0;
        }
    }

    /// @dev Quote the opposite token at `sqrtRatioX96`.
    function _quoteAtSqrt(uint160 sqrtRatioX96, uint256 amount, bool baseIsToken0) internal pure returns (uint256) {
        if (sqrtRatioX96 == 0) return 0;
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return baseIsToken0
                ? Math.mulDiv(ratioX192, amount, 1 << 192)
                : Math.mulDiv(1 << 192, amount, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return baseIsToken0 ? Math.mulDiv(ratioX128, amount, 1 << 128) : Math.mulDiv(1 << 128, amount, ratioX128);
    }
}
