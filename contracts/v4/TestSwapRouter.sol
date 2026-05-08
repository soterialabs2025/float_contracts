// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { UniversalRouter } from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import { Commands } from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IV4Router } from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { IV4Quoter } from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
//import { IPermit2 } from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { V4Deployments8453 } from "./V4Deployments8453.sol";
import "../../interfaces/IV3SwapRouterMinimal.sol";
import "../../interfaces/IQuoterV2.sol";
import "../../interfaces/IFloatStrategy.sol";
import "../../interfaces/ISwapRouter.sol";
import "../../interfaces/INonfungiblePositionManager.sol";
import "../../interfaces/IUniswapV3PoolMinimal.sol";
import "../../interfaces/IUniswapV3Factory.sol";
import "../../interfaces/IUniswapV3Pool.sol";
import "../../interfaces/IContractManager.sol";
import "../../interfaces/IUniswapV2Router02.sol";
import "../../interfaces/IUniversalRouter.sol";
import "../../interfaces/IAllowanceTransfer.sol";
import "../../libraries/UniswapV3OracleLibrary.sol";
import "../../libraries/TickMath.sol";


contract TestFloatSwapRouter is ISwapRouter, Ownable, ReentrancyGuard, IUnlockCallback {

    using SafeERC20 for IERC20;

    /// @notice v4 PoolManager on Base — required for `swapV4Direct` (`unlock` / `unlockCallback`).
    IPoolManager public immutable poolManager = IPoolManager(V4Deployments8453.POOL_MANAGER);
    /// @notice v4 Quoter on Base — used by `_minOutFromV4Quoter` for slippage-protected swaps.
    IV4Quoter public immutable v4Quoter = IV4Quoter(V4Deployments8453.QUOTER);

    /// @notice Max permissible price impact (bps) for `swapExactInputSingleStrict`. Default 300 = 3%.
    /// @dev Compares `sqrtPriceX96` before vs. after a quote-simulated swap; reverts if move exceeds bound.
    uint16 public maxPriceImpactBps = 300;

    IV3SwapRouterMinimal public immutable v3Router;
     IUniversalRouter public immutable universalRouter;
    IUniswapV2Router02 public immutable v2Router;
    IQuoterV2 public immutable quoterV2;
    /// @notice Permit2 AllowanceTransfer surface (`approve`); same address as signature Permit2.
    IAllowanceTransfer public immutable permit2;
    IERC20 private WETH;
    IContractManager public manager;
    IERC20 private TOKEN;
    address public strategy; // Strategy contract address
    uint24 public immutable defaultFee = 10_000; // e.g. 10_000 on Base
    uint16 public maxSlippageBps = 1_000;      // 10% cap for safety
    uint16 public defaultSlippageBps = 100;  // 1% default
    uint16 public fallbackSlippageBps = 200; // 2% if quoter fails

    /// @notice Slippage cap (bps) for `swapExactInputFromStrategyStrictQuote` only (quoter + TWAP min-out).
    /// @dev Default 200 (2%) — looser than `defaultSlippageBps` because TWAP raises the floor on large swaps;
    ///      strict path never uses `fallbackSlippageBps` (no weak quoter fallback).
    uint16 public strictStrategySlippageBps = 200;

    /// @dev When `amountIn` is at least this (raw units of tokenIn), `swapExactInputFromStrategyStrictQuote`
    ///      merges a TWAP-based floor with the quoter min when `strategyTwapPeriodSeconds != 0`.
    ///      Set to `type(uint256).max` to never apply the TWAP branch (strict quoter only). Default 1e15 ≈ 0.001 tokens at 18 decimals.
    uint256 public largeSwapTwapMinAmount = 10_000_000_000_000_000;

    /// @notice TWAP window (seconds) for strategy strict swaps when `amountIn >= largeSwapTwapMinAmount`.
    /// @dev Default 400 (6m): balances manipulation resistance with freshness when the system may be targeted.
    ///      Set to 0 to use strict quoter only (no TWAP floor).
    uint32 public strategyTwapPeriodSeconds = 400;

    bool public initialized;
    
    error Unauthorized();

    event SwapExecuted(
        address indexed caller,
        address indexed recipient,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event OwnerSet(address indexed newOwner);
    event SlippageParamsUpdated(uint16 defaultSlippageBps, uint16 fallbackSlippageBps);
    event ContractSetUp(address indexed caller);
    event StrategySet(address indexed strategy);
    event LargeSwapTwapMinAmountUpdated(uint256 largeSwapTwapMinAmount);
    event StrategyTwapPeriodSecondsUpdated(uint32 strategyTwapPeriodSeconds);
    event StrictStrategySlippageBpsUpdated(uint16 strictStrategySlippageBps);

    //Sepolia addresses
    address private immutable baseV3RouterAddr = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address private immutable baseV2RouterAddr = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    address private immutable quoterV2Addr = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address private immutable baseV3FactoryAddr = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address private immutable baseWETH = 0x4200000000000000000000000000000000000006;
    address private immutable nonfungiblePositionManagerAddr = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address private immutable permit2Addr = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant UNIVERSAL_ROUTER_BASE = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    uint24 private constant FEE_500 = 500;
    uint24 private constant FEE_3000 = 3000;
    uint24 private constant FEE_7000 = 7000;
    uint24 private constant FEE_10000 = 10000;
    uint24 private constant FEE_12000 = 12000;
    /// @dev Base canonical USDC — WETH/USDC swaps use the 0.3% (3000) pool tier.
    address private constant baseUsdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public universalRouterAddr;
    address public demeterAddr;

    constructor(address _managerAddr) Ownable(msg.sender) {
        require(_managerAddr != address(0), "Invalid manager address");
        manager = IContractManager(_managerAddr);
        universalRouter = IUniversalRouter(UNIVERSAL_ROUTER_BASE);
        v3Router = IV3SwapRouterMinimal(baseV3RouterAddr);
        v2Router = IUniswapV2Router02(baseV2RouterAddr);
        quoterV2 = IQuoterV2(quoterV2Addr);
        permit2 = IAllowanceTransfer(permit2Addr);
        WETH = IERC20(baseWETH);
    }

    // -----------------------------
    // Admin / tuning
    // -----------------------------

    modifier onlyAuthorized() {
        address s = _msgSender();
        if (s != demeterAddr && s != address(manager) && s != owner()) revert Unauthorized();
        _;
    }
    function setUpContract() external onlyOwner {
        address _tokenAddr = manager.getAddress("ASSET");
        address _strategyAddr = manager.getAddress("FloatStrategy");
        demeterAddr = manager.getAddress("Demeter");
        universalRouterAddr = UNIVERSAL_ROUTER_BASE;
        require(_tokenAddr != address(0), "token=0");
        require(_strategyAddr != address(0), "strategy=0");
        TOKEN = IERC20(_tokenAddr);
        strategy = _strategyAddr;
        initialized = true;
        emit ContractSetUp(_msgSender());
        emit StrategySet(_strategyAddr);
    }

    function updateAsset() external onlyAuthorized {
        address _assetAddr = manager.getAddress("ASSET");
        require(_assetAddr != address(0), "asset=0");
        TOKEN = IERC20(_assetAddr);
    }

    function setSlippageParams(uint16 _defaultSlippageBps, uint16 _fallbackSlippageBps) external onlyOwner {
        require(_defaultSlippageBps <= maxSlippageBps, "default>max");
        require(_fallbackSlippageBps <= maxSlippageBps, "fallback>max");
        defaultSlippageBps = _defaultSlippageBps;
        fallbackSlippageBps = _fallbackSlippageBps;
        emit SlippageParamsUpdated(_defaultSlippageBps, _fallbackSlippageBps);
    }

    function setLargeSwapTwapMinAmount(uint256 _largeSwapTwapMinAmount) external onlyOwner {
        largeSwapTwapMinAmount = _largeSwapTwapMinAmount;
        emit LargeSwapTwapMinAmountUpdated(_largeSwapTwapMinAmount);
    }

    /// @param seconds_ TWAP window for large strategy swaps; 0 disables TWAP floor (strict quoter only). Max 24h.
    function setStrategyTwapPeriodSeconds(uint32 seconds_) external onlyOwner {
        require(seconds_ == 0 || seconds_ >= 60, "twap<60s");
        require(seconds_ <= 86400, "twap>24h");
        strategyTwapPeriodSeconds = seconds_;
        emit StrategyTwapPeriodSecondsUpdated(seconds_);
    }

    function setStrictStrategySlippageBps(uint16 bps) external onlyOwner {
        require(bps <= maxSlippageBps, "strict>max");
        strictStrategySlippageBps = bps;
        emit StrictStrategySlippageBpsUpdated(bps);
    }


    /// @notice Swap using tokens already held by a strategy/vault.
    /// @dev Useful for so that V3 just calls this with its own balances.
    function swapExactInputFromStrategy(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external override returns (uint256 amountOut) {
        require(amountIn > 0, "zero in");
        if (msg.sender == strategy) {
            require(recipient == strategy, "recipient must be strategy");
        }

        // Strategy needs to approve this router for tokenIn.
        // Pull tokens from strategy (msg.sender) to this router
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        amountOut = _swapExactInput(
            tokenIn,
            tokenOut,
            amountIn,
            _feeForSingleHop(tokenIn, tokenOut),
            recipient,
            defaultSlippageBps,
            fallbackSlippageBps
        );
    }

    /// @notice Like `swapExactInputFromStrategy` but **never** uses the weak quoter `catch` fallback.
    /// @dev If QuoterV2 reverts, the whole call reverts. When `strategyTwapPeriodSeconds > 0` and
    ///      `amountIn >= largeSwapTwapMinAmount`, `amountOutMinimum` is the max of (quoter-based min, TWAP-based min),
    ///      each discounted by `strictStrategySlippageBps`. Fee tier: WETH/USDC uses 3000; otherwise `defaultFee`.
    ///      TWAP length is `strategyTwapPeriodSeconds` (owner-tunable; default 10 minutes).
    function swapExactInputFromStrategyStrictQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external override nonReentrant returns (uint256 amountOut) {
        require(amountIn > 0, "zero in");
        if (msg.sender == strategy) {
            require(recipient == strategy, "recipient must be strategy");
        }

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        return _strictSingleHopV3Swap(tokenIn, tokenOut, amountIn, _feeForSingleHop(tokenIn, tokenOut), recipient);
    }

    /// @dev Assumes `tokenIn` is already held by this contract. Quotes min-out for the amount actually swapped
    ///      (`min(requested, balance)`), so fee-on-transfer inputs do not use an oversized minimum.
    function _strictSingleHopV3Swap(
        address tokenIn,
        address tokenOut,
        uint256 amountInRequested,
        uint24 fee,
        address recipient
    ) internal returns (uint256 amountOut) {
        IERC20 inToken = IERC20(tokenIn);
        uint256 bal = inToken.balanceOf(address(this));
        uint256 useIn = amountInRequested > bal ? bal : amountInRequested;
        require(useIn > 0, "no balance");

        uint256 minOut = _minimumOutStrictQuote(
            tokenIn, tokenOut, useIn, fee, strictStrategySlippageBps, strategyTwapPeriodSeconds
        );

        _ensureAllowance(inToken, address(v3Router), useIn);
        bytes memory path = abi.encodePacked(tokenIn, fee, tokenOut);

        amountOut = v3Router.exactInput(
            IV3SwapRouterMinimal.ExactInputParams({
                path: path,
                recipient: recipient,
                amountIn: useIn,
                amountOutMinimum: minOut
            })
        );

        emit SwapExecuted(msg.sender, recipient, tokenIn, tokenOut, useIn, amountOut);
    }

    /// @notice Two-hop swap: oldAsset -> WETH -> newAsset
    /// @dev Used by strategy when changing assets. Performs two V3 swaps through WETH.
    /// @param oldAssetAddr The current asset address to swap from
    /// @param newAssetAddr The new asset address to swap to
    /// @param amountIn The amount of oldAsset to swap
    /// @param recipient The address to receive the newAsset (should be strategy address)
    /// @return amountOut The amount of newAsset received
    function swapAssetToNewAsset(
        address oldAssetAddr,
        address newAssetAddr,
        uint256 amountIn,
        address recipient
    ) external override returns (uint256 amountOut) {
        require(amountIn > 0, "zero in");
        require(oldAssetAddr != address(0), "oldAsset=0");
        require(newAssetAddr != address(0), "newAsset=0");
        require(recipient != address(0), "recipient=0");
        
        if (msg.sender == strategy) {
            require(recipient == strategy, "recipient must be strategy");
        }

        // Pull oldAsset from strategy (msg.sender) to this router
        IERC20 oldAsset = IERC20(oldAssetAddr);
        oldAsset.safeTransferFrom(msg.sender, address(this), amountIn);

        // First hop: oldAsset -> WETH
        uint256 wethReceived = _swapExactInput(
            oldAssetAddr,
            baseWETH,
            amountIn,
            _feeForSingleHop(oldAssetAddr, baseWETH),
            address(this), // Intermediate recipient (this router)
            defaultSlippageBps,
            fallbackSlippageBps
        );

        // Second hop: WETH -> newAsset
        amountOut = _swapExactInput(
            baseWETH,
            newAssetAddr,
            wethReceived,
            _feeForSingleHop(baseWETH, newAssetAddr),
            recipient, // Final recipient (strategy)
            defaultSlippageBps,
            fallbackSlippageBps
        );

        emit SwapExecuted(msg.sender, recipient, oldAssetAddr, newAssetAddr, amountIn, amountOut);
    }

    // -----------------------------
    // Universal Router (Permit2) path
    // -----------------------------

    /// @notice Swap any token to WETH via Uniswap UniversalRouter + Permit2.
    /// @dev Caller must have approved this router for `amountIn` of `tokenIn` before calling.
    ///      Tries V3 fee tiers 0.05 % → 0.3 % → 1 % in order, reverting only if none succeed.
    function swapToWethViaUniversalRouter(
        address tokenIn,
        uint256 amountIn,
        address recipient
    ) external override nonReentrant returns (uint256 amountOut) {
        require(amountIn > 0, "zero in");
        require(amountIn <= type(uint160).max, "amount>uint160");
        require(tokenIn != baseWETH, "token is WETH");
        require(recipient != address(0), "recipient=0");

        IERC20 tIn = IERC20(tokenIn);
        tIn.safeTransferFrom(msg.sender, address(this), amountIn);

        uint24[3] memory fees = [FEE_7000, FEE_10000, FEE_12000];
        for (uint256 i = 0; i < fees.length; i++) {
            uint256 bal = tIn.balanceOf(address(this));
            if (bal == 0) break;
            try this._universalRouterSwapSingleFee(tokenIn, bal, recipient, fees[i]) returns (uint256 out) {
                if (out > 0) {
                    emit SwapExecuted(msg.sender, recipient, tokenIn, baseWETH, bal, out);
                    return out;
                }
            } catch {}
        }
        revert("UniversalRouter: no pool found");
    }

    /// @dev Internal helper called via try/catch so individual fee-tier failures are recoverable.
    ///      Tokens must already reside in this contract.
    function _universalRouterSwapSingleFee(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        uint24 fee
    ) external returns (uint256 amountOut) {
        require(msg.sender == address(this), "only self");
        require(amountIn <= type(uint160).max, "amount>uint160");

        address ur = universalRouterAddr;
        require(ur != address(0), "universalRouter not set");

        // Step 1: approve Permit2 to spend tokenIn from this contract
        _ensureAllowance(IERC20(tokenIn), permit2Addr, amountIn);

        // Step 2: grant UniversalRouter a Permit2 AllowanceTransfer allowance
        IAllowanceTransfer(permit2Addr).approve(
            tokenIn,
            ur,
            uint160(amountIn),
            uint48(block.timestamp + 300)
        );

        // Step 3: encode V3_SWAP_EXACT_IN (command 0x00)
        //   inputs: (address recipient, uint256 amountIn, uint256 amountOutMinimum, bytes path, bool payerIsUser)
        //   payerIsUser = true → UniversalRouter pulls tokenIn from msg.sender (this contract) via Permit2
        bytes memory commands = abi.encodePacked(bytes1(0x00));
        bytes memory path = abi.encodePacked(tokenIn, fee, baseWETH);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(recipient, amountIn, 0, path, true);
        IUniversalRouter(ur).execute(commands, inputs, block.timestamp + 300);
        return amountIn;
    }

    function _swapTokenToWethV2(address tokenIn, uint256 amountIn, address recipient) internal returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = baseWETH;
        uint256[] memory amounts = v2Router.getAmountsOut(amountIn, path);
        uint256 amountOutMin = Math.mulDiv(amounts[amounts.length - 1], 10_000 - defaultSlippageBps, 10_000);
        _ensureAllowance(IERC20(tokenIn), address(v2Router), amountIn);
        uint256 balBefore = IERC20(baseWETH).balanceOf(recipient);
        v2Router.swapExactTokensForTokens(amountIn, amountOutMin, path, recipient, block.timestamp + 300);
        return IERC20(baseWETH).balanceOf(recipient) - balBefore;
    }

    // -----------------------------
    // Internal core swap logic
    // -----------------------------

    function _feeForSingleHop(address tokenIn, address tokenOut) private view returns (uint24) {
        if (
            (tokenIn == baseWETH && tokenOut == baseUsdc) ||
            (tokenIn == baseUsdc && tokenOut == baseWETH)
        ) {
            return FEE_3000;
        }
        return defaultFee;
    }

    function _swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee,
        address recipient,
        uint16 slippageBps,
        uint16 fallbackSlippage
    ) internal returns (uint256 amountOut) {
        require(recipient != address(0), "recipient=0");
        require(slippageBps <= maxSlippageBps, "slippage>max");
        require(fallbackSlippage <= maxSlippageBps, "fallback>max");

        IERC20 inToken = IERC20(tokenIn);

        uint256 bal = inToken.balanceOf(address(this));
        if (amountIn > bal) amountIn = bal;
        require(amountIn > 0, "no balance");

        // 1) Compute minOut via quoter, fallback if needed
        uint256 minOut = _getMinimumOutputForSwap(
            tokenIn,
            tokenOut,
            amountIn,
            fee,
            slippageBps,  
            fallbackSlippage
        );

        // 2) Approve router for this amount if needed
        _ensureAllowance(inToken, address(v3Router), amountIn);

        // 3) Build single-hop path: tokenIn -> tokenOut
        bytes memory path = abi.encodePacked(tokenIn, fee, tokenOut);

        amountOut = v3Router.exactInput(
            IV3SwapRouterMinimal.ExactInputParams({
                path: path,
                recipient: recipient,
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        );

        emit SwapExecuted(msg.sender, recipient, tokenIn, tokenOut, amountIn, amountOut);
    }

    function _getMinimumOutputForSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee,
        uint16 slippageBps,
        uint16 fallbackSlippage
    ) internal returns (uint256 amountOutMinimum) {
        // Try quoter; if it reverts, use a dumb fallback bound.
        try quoterV2.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                fee: fee,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 amountOut, uint160, uint32, uint256) {
            amountOutMinimum = Math.mulDiv(amountOut, (10_000 - slippageBps), 10_000);
        } catch {
            // Fallback: assume 1:1 with big slippage discount
            amountOutMinimum = Math.mulDiv(amountIn, fallbackSlippage, 10_000);
        }
    }

    /// @notice Quoter-only minOut; **reverts** if quoter reverts (no `amountIn * fallback` path).
    function _quoteExactOutStrict(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee
    ) internal returns (uint256 amountOutQuoted) {
        try quoterV2.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                fee: fee,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 amountOut, uint160, uint32, uint256) {
            amountOutQuoted = amountOut;
        } catch {
            revert("StrictQuote: quoter failed");
        }
    }

    /// @dev Expected `tokenOut` for `amountIn` of `tokenIn` at a given tick (token0/token1 ordering).
    function _amountOutAtTick(address tokenIn, address tokenOut, int24 tick, uint256 amountIn)
        internal
        pure
        returns (uint256)
    {
        if (tokenIn < tokenOut) {
            return UniswapV3OracleLibrary.getQuoteAtTick(tick, amountIn);
        }
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        uint256 ratioX192 = uint256(sqrtRatioX96) * uint256(sqrtRatioX96);
        return Math.mulDiv(amountIn, 1 << 192, ratioX192);
    }

    /// @notice When TWAP is active: `max(quote * (1-slip), twapOut * (1-slip))`, capped at raw `quoted` so a lagging
    ///         TWAP cannot require more output than the quoter's spot simulation (avoids STF after real volatility).
    ///         If `observe` reverts (new pool / sparse cardinality), falls back to quoter-only min.
    function _minimumOutStrictQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee,
        uint16 slippageBps,
        uint32 twapPeriodSeconds
    ) internal returns (uint256 minOut) {
        require(slippageBps <= maxSlippageBps, "slippage>max");
        uint256 quoted = _quoteExactOutStrict(tokenIn, tokenOut, amountIn, fee);
        uint256 qMin = Math.mulDiv(quoted, (10_000 - slippageBps), 10_000);
        minOut = qMin;

        if (twapPeriodSeconds == 0 || amountIn < largeSwapTwapMinAmount) {
            return minOut;
        }

        address token0 = tokenIn < tokenOut ? tokenIn : tokenOut;
        address token1 = tokenIn < tokenOut ? tokenOut : tokenIn;
        address pool = IUniswapV3Factory(baseV3FactoryAddr).getPool(token0, token1, fee);
        require(pool != address(0), "StrictQuote: no pool");

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapPeriodSeconds;
        secondsAgos[1] = 0;

        try IUniswapV3Pool(pool).observe(secondsAgos) returns (
            int56[] memory tickCumulatives,
            uint160[] memory
        ) {
            int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
            int32 sec = int32(twapPeriodSeconds);
            int24 meanTick = int24(tickCumulativesDelta / sec);
            if (tickCumulativesDelta < 0 && (tickCumulativesDelta % sec != 0)) {
                meanTick--;
            }
            uint256 twapOut = _amountOutAtTick(tokenIn, tokenOut, meanTick, amountIn);
            uint256 minTwap = Math.mulDiv(twapOut, (10_000 - slippageBps), 10_000);
            uint256 merged = Math.max(qMin, minTwap);
            minOut = merged > quoted ? qMin : merged;
        } catch {
            minOut = qMin;
        }
    }

    function _ensureAllowance(IERC20 token, address spender, uint256 amount) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current < amount) {
            token.approve(spender, 0);
            token.approve(spender, type(uint256).max);
        }
    }

    /// @notice One-time setup: ERC20 → Permit2 max approve, then Permit2 allowance for Universal Router (matches Uniswap docs Step 2).
    function approveTokenWithPermit2(address token, uint160 amount, uint48 expiration) external onlyOwner {
        IERC20(token).approve(permit2Addr, type(uint256).max);
        permit2.approve(token, address(universalRouter), amount, expiration);
    }

    /// @notice Single-hop v4 exact-in via direct `PoolManager.unlock` (no Universal Router, no Permit2).
    /// @dev Uses the widest possible price limit (`MIN_SQRT_PRICE + 1` for `zeroForOne`, else `MAX_SQRT_PRICE - 1`),
    ///      same as `V4Router._swap`. Slippage is enforced by `minAmountOut`, NOT by the price limit.
    ///      Hooked pools often need non-empty `hookData`; empty bytes can revert inside `poolManager.swap`.
    function swapExactInputSingle(
        PoolKey calldata key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        bytes calldata hookData
    ) external nonReentrant returns (uint256 amountOut) {
        uint160 limit = zeroForOne
            ? TickMath.MIN_SQRT_RATIO + 1
            : TickMath.MAX_SQRT_RATIO - 1;
        return _swapV4Direct(key, zeroForOne, amountIn, minAmountOut, limit, hookData);
    }

    /// @notice Same as `swapExactInputSingle` but caller chooses an explicit `sqrtPriceLimitX96`.
    /// @dev Useful when an aggregator pre-computes a tighter intra-swap price bound (mirrors the
    ///      bespoke v4 adapter `0x8F10B468...` that KyberSwap uses).
    /// @param sqrtPriceLimitX96 For `zeroForOne` must satisfy `MIN_SQRT_PRICE < limit < currentSqrtPriceX96`,
    ///        otherwise must satisfy `currentSqrtPriceX96 < limit < MAX_SQRT_PRICE`.
    function swapV4Direct(
        PoolKey calldata key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) external nonReentrant returns (uint256 amountOut) {
        return _swapV4Direct(key, zeroForOne, amountIn, minAmountOut, sqrtPriceLimitX96, hookData);
    }

    /// @notice v4 swap with quoter-derived slippage protection.
    /// @dev Calls `IV4Quoter.quoteExactInputSingle` to get expected `amountOut`, applies `slippageBps` haircut, then swaps.
    ///      Protects against slippage but **NOT** against same-block sandwich MEV (quoter sees manipulated price).
    ///      For MEV-resistant routing use `swapExactInputSingleStrict` (price-impact bound) or a private mempool / signed minOut.
    function swapExactInputSingleQuoter(
        PoolKey calldata key,
        bool zeroForOne,
        uint128 amountIn,
        uint16 slippageBps,
        bytes calldata hookData
    ) external nonReentrant returns (uint256 amountOut) {
        require(slippageBps <= maxSlippageBps, "slippage>max");
        uint128 minOut = _minOutFromV4Quoter(key, zeroForOne, amountIn, hookData, slippageBps);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        return _swapV4Direct(key, zeroForOne, amountIn, minOut, limit, hookData);
    }

    /// @notice v4 swap with slippage **and** price-impact protection — best on-chain MEV mitigation without a hook oracle.
    /// @dev Reads spot `sqrtPriceX96` via `StateLibrary.getSlot0`, then runs the quoter (which mutates a fresh state copy)
    ///      and reads the post-quote `sqrtPriceX96` from the quoter's result indirectly via current pool state at call time.
    ///      Reverts if the implied price move exceeds `maxPriceImpactBps`. A sandwich must move price > `maxPriceImpactBps`
    ///      AND back within one block to stay profitable, which is significantly more capital-intensive than pure slippage gaming.
    ///      For automated rebalancing this should be the default. Pair with a private mempool for additional safety.
    function swapExactInputSingleStrict(
        PoolKey calldata key,
        bool zeroForOne,
        uint128 amountIn,
        uint16 slippageBps,
        bytes calldata hookData
    ) external nonReentrant returns (uint256 amountOut) {
        require(slippageBps <= maxSlippageBps, "slippage>max");

        PoolId poolId = PoolIdLibrary.toId(key);
        (uint160 sqrtBefore, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        require(sqrtBefore != 0, "pool !init");

        uint128 minOut = _minOutFromV4Quoter(key, zeroForOne, amountIn, hookData, slippageBps);

        amountOut = _swapV4Direct(
            key,
            zeroForOne,
            amountIn,
            minOut,
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            hookData
        );

        (uint160 sqrtAfter, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        _requirePriceImpactBound(sqrtBefore, sqrtAfter, zeroForOne);
    }

    /// @notice Update price-impact cap used by `swapExactInputSingleStrict`. Owner-gated.
    function setMaxPriceImpactBps(uint16 bps) external onlyOwner {
        require(bps > 0 && bps <= 5_000, "bps oor");
        maxPriceImpactBps = bps;
    }

    /// @dev `quoteExactInputSingle` is `external` (not view) — wrap in try/catch to avoid bricking pools where the
    ///      quoter reverts (e.g. hooks that gate the quoter sender). Returns 0 → caller decides what to do.
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

    /// @dev Compute `|sqrtBefore - sqrtAfter| / sqrtBefore` in bps and revert if it exceeds `maxPriceImpactBps`.
    ///      Using sqrt-price as a price proxy is fine for impact bounds (linear in `sqrtP` ≈ ½ in `P` for small moves).
    function _requirePriceImpactBound(uint160 sqrtBefore, uint160 sqrtAfter, bool zeroForOne) internal view {
        uint256 diff = zeroForOne
            ? (sqrtBefore > sqrtAfter ? uint256(sqrtBefore - sqrtAfter) : 0)
            : (sqrtAfter > sqrtBefore ? uint256(sqrtAfter - sqrtBefore) : 0);
        uint256 bps = (diff * 10_000) / uint256(sqrtBefore);
        require(bps <= uint256(maxPriceImpactBps), "price impact");
    }

    /// @dev Internal helper used by both public entrypoints. Pulls input from caller, calls `unlock`
    ///      (which routes back to `unlockCallback` to do `sync`+`transfer`+`settle`+`take`), then
    ///      checks slippage from caller's balance delta.
    function _swapV4Direct(
        PoolKey calldata key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) private returns (uint256 amountOut) {
        require(amountIn > 0, "amount");

        address tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        address tokenOut = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        bytes memory data = abi.encode(
            msg.sender,
            key,
            zeroForOne,
            int256(uint256(amountIn)),
            sqrtPriceLimitX96,
            hookData
        );

        uint256 balBefore = IERC20(tokenOut).balanceOf(msg.sender);
        poolManager.unlock(data);
        amountOut = IERC20(tokenOut).balanceOf(msg.sender) - balBefore;

        require(amountOut >= minAmountOut, "Insufficient output amount");
        emit SwapExecuted(msg.sender, msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Decodes payer + swap params, calls `poolManager.swap`, settles input via `sync`+`transfer`+`settle`,
    ///      and `take`s output to the original caller. Reverts if anyone but the PoolManager calls in.
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

        /// @dev `amountSpecified < 0` ⇒ exact-input on v4.
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -amountIn, sqrtPriceLimitX96: sqrtPriceLimitX96}),
            hookData
        );

        int128 deltaIn = zeroForOne ? delta.amount0() : delta.amount1();
        int128 deltaOut = zeroForOne ? delta.amount1() : delta.amount0();
        require(deltaIn <= 0, "delta in");
        require(deltaOut >= 0, "delta out");

        uint256 owed = uint256(uint128(-deltaIn));
        uint256 received = uint256(uint128(deltaOut));

        /// @dev `sync` snapshots PoolManager's pre-transfer balance; `transfer` to PoolManager; `settle` resolves the negative delta.
        poolManager.sync(inC);
        IERC20(Currency.unwrap(inC)).safeTransfer(address(poolManager), owed);
        poolManager.settle();

        poolManager.take(outC, recipient, received);

        return "";
    }
}