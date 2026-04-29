// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IV3SwapRouterMinimal.sol";
import "../interfaces/IQuoterV2.sol";
import "../interfaces/IFloatStrategy.sol";
import "../interfaces/ISwapRouter.sol";
import "../interfaces/INonfungiblePositionManager.sol";
import "../interfaces/IUniswapV3PoolMinimal.sol";
import "../interfaces/IUniswapV3Factory.sol";
import "../interfaces/IUniswapV3Pool.sol";
import "../interfaces/IContractManager.sol";
import "../interfaces/IUniswapV2Router02.sol";
import "../interfaces/IUniversalRouter.sol";
import "../interfaces/IAllowanceTransfer.sol";
import "../libraries/UniswapV3OracleLibrary.sol";
import "../libraries/TickMath.sol";


/// @notice Minimal Permit2 interface (single-token permit+transfer use case).
/// @dev Replace with full official interface in production.
interface IPermit2 {
    struct PermitTransferFrom {
        IERC20 token;
        uint256 amount;
        uint256 expiration;
        uint256 nonce;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}
 

contract FloatSwapRouter is ISwapRouter, Ownable, ReentrancyGuard { 

    using SafeERC20 for IERC20;

    IV3SwapRouterMinimal public immutable v3Router;
    IUniswapV2Router02 public immutable v2Router;
    IQuoterV2 public immutable quoterV2;
    IPermit2 public immutable permit2;
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
    uint24 private constant FEE_10000 = 10000;
    /// @dev Base canonical USDC — WETH/USDC swaps use the 0.3% (3000) pool tier.
    address private constant baseUsdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public universalRouterAddr;
    address public demeterAddr;

    constructor(address _managerAddr) Ownable(msg.sender) {
        require(_managerAddr != address(0), "Invalid manager address");
        manager = IContractManager(_managerAddr);
        v3Router = IV3SwapRouterMinimal(baseV3RouterAddr);
        v2Router = IUniswapV2Router02(baseV2RouterAddr);
        quoterV2 = IQuoterV2(quoterV2Addr);
        permit2 = IPermit2(permit2Addr);
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
        address _tokenAddr = manager.getAddress("LiquidASSET");
        address _strategyAddr = manager.getAddress("FloatStrategy");
        demeterAddr = manager.getAddress("Demeter");
        address _ur = manager.getAddress("UniversalRouter");
        universalRouterAddr = _ur != address(0) ? _ur : UNIVERSAL_ROUTER_BASE;
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

        uint24[3] memory fees = [FEE_500, FEE_3000, FEE_10000];
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

        // Strict quoter + optional TWAP floor (reverts if quoter fails; no weak fallback)
        uint256 minOut = _minimumOutStrictQuote(
            tokenIn, baseWETH, amountIn, fee, strictStrategySlippageBps, strategyTwapPeriodSeconds
        );

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
        inputs[0] = abi.encode(recipient, amountIn, minOut, path, true);

        uint256 balBefore = IERC20(baseWETH).balanceOf(recipient);
        IUniversalRouter(ur).execute(commands, inputs, block.timestamp + 300);
        amountOut = IERC20(baseWETH).balanceOf(recipient) - balBefore;
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
}