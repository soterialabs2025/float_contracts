// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./SushiV3Deployments4663.sol";
import "./libraries/TickMath.sol";
import "./interfaces/IAutoSwapRouterSv3.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./interfaces/IUniswapV3PoolMinimal.sol";
import "./interfaces/IUniswapV3SwapCallback.sol";

/// @title AutoSwapRouterSv3
/// @notice Authorized single-hop Sushi V3 swaps via direct `pool.swap` (no RedSnwapper / SwapRouter02).
/// @dev Caller supplies `minAmountOut`. Floor is TWAP-gated spot; router does not quote.
contract AutoSwapRouterSv3 is IAutoSwapRouterSv3, IUniswapV3SwapCallback, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant DIVISOR = 10_000;

    /// @dev Uni V3 TickMath bounds (avoid relying on library `internal` constant visibility).
    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    IUniswapV3Factory public immutable factory = IUniswapV3Factory(SushiV3Deployments4663.FACTORY);

    /// @notice Haircut on the TWAP-admitted floor, covering liquidity-based price impact and read-to-execute drift.
    uint16 public strictStrategySlippageBps = 200;
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
    error InsufficientOutput();
    error Expired();
    error OracleUnavailable();
    error PriceOutOfBand();

    event StrategyFactoryUpdated(address indexed factory);
    event StrategyAuthorized(address indexed strategy);
    event StrategyDeauthorized(address indexed strategy);
    event StrictStrategySlippageUpdated(uint16 bps);
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

    function setStrictStrategySlippageBps(uint16 bps) external onlyOwner {
        // Capped well below `DIVISOR`: a tolerance approaching 100% is indistinguishable from having no floor.
        if (bps > 1_000) revert InvalidSlippage();
        strictStrategySlippageBps = bps;
        emit StrictStrategySlippageUpdated(bps);
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
        uint256 deadline
    ) external override nonReentrant returns (uint256 amountOut) {
        if (!isAuthorizedStrategy[msg.sender]) revert Unauthorized();
        if (amountIn == 0) revert ZeroAmount();
        if (deadline != 0 && block.timestamp > deadline) revert Expired();

        address pool = factory.getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) revert InvalidPool();
        uint256 minOut = _minOut(pool, tokenIn, amountIn, fee, maxDevBps);
        if (minOut == 0) revert ZeroAmount();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

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
        // `pool.swap` enforces no minimum of its own, so the floor is checked here against what actually landed.
        amountOut = IERC20(tokenOut).balanceOf(msg.sender) - balOutBefore;
        if (amountOut < minOut) revert InsufficientOutput();

        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @dev TWAP-admitted spot floor. Reverts if unpriceable.
    function _minOut(address pool, address tokenIn, uint128 amountIn, uint24 fee, uint256 maxDevBps)
        internal
        view
        returns (uint256)
    {
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
        return Math.mulDiv(afterPoolFee, DIVISOR - strictStrategySlippageBps, DIVISOR);
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
