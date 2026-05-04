// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import "./interfaces/ISwapRouterV4.sol";
import "./interfaces/IFloatV4StrategySwapRouter.sol";
import "./V4Deployments8453.sol";

/// @title FloatSwapRouterV4
/// @notice Float-facing router: token → WETH via Universal Router `V4_SWAP` (see Uniswap v4 swap routing guide).
/// @dev Base (8453) only: infra addresses match `V4Deployments8453` (Permit2, Universal Router, Quoter, WETH).
contract FloatSwapRouterV4 is ISwapRouterV4, IFloatV4StrategySwapRouter, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniversalRouter public immutable universalRouter = IUniversalRouter(V4Deployments8453.UNIVERSAL_ROUTER);
    IAllowanceTransfer public immutable permit2 = IAllowanceTransfer(V4Deployments8453.PERMIT2);
    IV4Quoter public immutable quoterV4 = IV4Quoter(V4Deployments8453.QUOTER);
    IERC20 public immutable WETH = IERC20(0x4200000000000000000000000000000000000006);

    /// @notice Float asset on Base — same as `ADDRESSES.md` ASSET.
    address internal constant TEST_SWAP_TOKEN_OUT = 0xAB3f23c2ABcB4E12Cc8B593C218A7ba64Ed17Ba3;
    /// @dev Pool params from `ADDRESSES.md` (fee / tickSpacing / hooks). If your swap still reverts, the
    /// liquid pool may be a different `PoolKey` (e.g. Uniswap UI pool with dynamic fee + hooks); use
    /// `swapTestExactInputSingle` with the exact key from an `Initialize` log or the v4 SDK config.
    uint24 internal constant TEST_SWAP_FEE = 12000;
    int24 internal constant TEST_SWAP_TICK_SPACING = 240;
    IHooks internal constant TEST_SWAP_HOOKS = IHooks(address(0));

    /// @notice Strategy allowed to call `swapExactInputSingleFromStrategy` (set after deploy).
    address public strategy;

    uint16 public defaultSlippageBps = 100;

    event SwapExecuted(
        address indexed caller, address indexed recipient, address tokenIn, uint256 amountIn, uint256 amountOut
    );
    event DefaultSlippageBpsUpdated(uint16 bps);

    error ZeroAddress();
    error ZeroAmount();
    error TokenIsWETH();
    error BadPoolKey();

    /// @dev Owner is the account that deploys (`_msgSender()`); use `transferOwnership` if that must differ.
    constructor() Ownable(_msgSender()) {}

    function setDefaultSlippageBps(uint16 bps) external onlyOwner {
        require(bps < 10_000, "slippage");
        defaultSlippageBps = bps;
        emit DefaultSlippageBpsUpdated(bps);
    }

    function setStrategy(address s) external override onlyOwner {
        strategy = s;
    }

    /// @inheritdoc IFloatV4StrategySwapRouter
    function swapExactInputSingleFromStrategy(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint128 minOutIfNoQuoter
    ) external override nonReentrant returns (uint256 amountOut) {
        require(msg.sender == strategy && strategy != address(0), "strategy");
        require(amountIn > 0 && amountIn <= type(uint128).max, "amount");

        IERC20 tokenIn = IERC20(Currency.unwrap(zeroForOne ? key.currency0 : key.currency1));
        IERC20 tokenOut = IERC20(Currency.unwrap(zeroForOne ? key.currency1 : key.currency0));

        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);

        uint128 minOut = _minOut(key, zeroForOne, uint128(amountIn), minOutIfNoQuoter, bytes(""));
        amountOut =
            _swapExactInSingleUr(key, zeroForOne, uint128(amountIn), minOut, tokenIn, tokenOut, msg.sender, bytes(""));
    }

    /// @notice TEST ONLY: same as two-arg version with `minOutIfNoQuoter = 0` (quoter + `defaultSlippageBps` when available).
    function swapTestWethForPoolToken(uint256 amountIn) external nonReentrant returns (uint256 amountOut) {
        return _swapTestWethForPoolToken(amountIn, 0);
    }

    /// @notice TEST ONLY: exact-in WETH → `TEST_SWAP_TOKEN_OUT` using hardcoded `PoolKey` (`ADDRESSES.md` tier).
    /// @dev Approve **this contract** for WETH, then call. `minOutIfNoQuoter` used if quoter reverts (often `0` while debugging).
    function swapTestWethForPoolToken(uint256 amountIn, uint128 minOutIfNoQuoter)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        return _swapTestWethForPoolToken(amountIn, minOutIfNoQuoter);
    }

    function _swapTestWethForPoolToken(uint256 amountIn, uint128 minOutIfNoQuoter) private returns (uint256 amountOut) {
        if (amountIn == 0 || amountIn > type(uint128).max) revert ZeroAmount();

        IERC20 tokenOut = IERC20(TEST_SWAP_TOKEN_OUT);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(WETH)),
            currency1: Currency.wrap(TEST_SWAP_TOKEN_OUT),
            fee: TEST_SWAP_FEE,
            tickSpacing: TEST_SWAP_TICK_SPACING,
            hooks: TEST_SWAP_HOOKS
        });

        WETH.safeTransferFrom(msg.sender, address(this), amountIn);

        uint128 minOut = _minOut(key, true, uint128(amountIn), minOutIfNoQuoter, bytes(""));
        amountOut =
            _swapExactInSingleUr(key, true, uint128(amountIn), minOut, WETH, tokenOut, msg.sender, bytes(""));
        emit SwapExecuted(msg.sender, msg.sender, address(WETH), amountIn, amountOut);
    }

    /// @notice TEST ONLY: same single-hop UR swap as production paths, but you supply the exact `PoolKey` + `hookData`
    /// (from v4 SDK / subgraph / `Initialize` event). Use when the hardcoded test key does not match the live pool.
    /// @dev Approve **this contract** for `tokenIn` (derived from `key` + `zeroForOne`), then call.
    function swapTestExactInputSingle(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint128 minOutIfNoQuoter,
        bytes calldata hookData
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0 || amountIn > type(uint128).max) revert ZeroAmount();
        IERC20 tokenIn = IERC20(Currency.unwrap(zeroForOne ? key.currency0 : key.currency1));
        IERC20 tokenOut = IERC20(Currency.unwrap(zeroForOne ? key.currency1 : key.currency0));
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        PoolKey memory keyMem = key;
        uint128 minOut = _minOut(keyMem, zeroForOne, uint128(amountIn), minOutIfNoQuoter, hookData);
        amountOut =
            _swapExactInSingleUr(keyMem, zeroForOne, uint128(amountIn), minOut, tokenIn, tokenOut, msg.sender, hookData);
        emit SwapExecuted(msg.sender, msg.sender, address(tokenIn), amountIn, amountOut);
    }

    /// @inheritdoc ISwapRouterV4
    function swapToWethViaUniversalRouterV4(PoolKey calldata key, uint256 amountIn, address recipient)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > type(uint128).max) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        address wethAddr = address(WETH);
        address tokenIn;
        if (c0 == wethAddr && c1 != wethAddr) {
            tokenIn = c1;
        } else if (c1 == wethAddr && c0 != wethAddr) {
            tokenIn = c0;
        } else {
            revert BadPoolKey();
        }
        if (tokenIn == wethAddr) revert TokenIsWETH();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        bool zeroForOne = tokenIn == c0;
        uint128 minOut = _minOutFromQuoter(key, zeroForOne, uint128(amountIn), bytes(""));

        PoolKey memory keyMem = key;
        amountOut = _swapExactInSingleUr(
            keyMem, zeroForOne, uint128(amountIn), minOut, IERC20(tokenIn), WETH, recipient, bytes("")
        );
        if (amountOut > 0) {
            emit SwapExecuted(msg.sender, recipient, tokenIn, amountIn, amountOut);
        }
    }

    /// @dev Prefer quoter + slippage; if quoter reverts or returns 0, use `minOut = 0` so swaps can still execute (integrators should set `defaultSlippageBps` / pool liquidity carefully).
    function _minOutFromQuoter(PoolKey calldata key, bool zeroForOne, uint128 amountIn, bytes memory hookData)
        private
        returns (uint128 minOut)
    {
        try quoterV4.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: amountIn, hookData: hookData
            })
        ) returns (uint256 quotedOut, uint256) {
            if (quotedOut == 0) {
                return 0;
            }
            minOut = uint128(Math.mulDiv(quotedOut, 10_000 - uint256(defaultSlippageBps), 10_000));
        } catch {
            minOut = 0;
        }
    }

    function _minOut(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minOutIfNoQuoter,
        bytes memory hookData
    ) internal returns (uint128 minOut) {
        address q = address(quoterV4);
        if (q == address(0)) {
            return minOutIfNoQuoter;
        }
        try quoterV4.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: amountIn, hookData: hookData
            })
        ) returns (uint256 quotedOut, uint256) {
            if (quotedOut == 0) minOut = minOutIfNoQuoter;
            else minOut = uint128(Math.mulDiv(quotedOut, 10_000 - uint256(defaultSlippageBps), 10_000));
        } catch {
            minOut = minOutIfNoQuoter;
        }
    }

    /// @dev Pull `amountIn` of `tokenIn` to this contract before calling.
    function _swapExactInSingleUr(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minOut,
        IERC20 tokenIn,
        IERC20 tokenOut,
        address outputTo,
        bytes memory hookData
    ) internal returns (uint256 amountOut) {
        address ur = address(universalRouter);
        _ensureAllowance(tokenIn, address(permit2), amountIn);
        permit2.approve(address(tokenIn), ur, uint160(amountIn), uint48(block.timestamp + 300));

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4SwapPayload(key, zeroForOne, amountIn, minOut, hookData);

        uint256 balBefore = tokenOut.balanceOf(address(this));
        IUniversalRouter(ur).execute(commands, inputs, block.timestamp + 300);
        amountOut = tokenOut.balanceOf(address(this)) - balBefore;
        if (amountOut > 0 && outputTo != address(this)) {
            tokenOut.safeTransfer(outputTo, amountOut);
        }
    }

    function _encodeV4SwapPayload(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minOut,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        bytes memory actions = _v4SwapActionBytes();
        bytes[] memory params = _v4SwapParamChunks(key, zeroForOne, amountIn, minOut, hookData);
        return abi.encode(actions, params);
    }

    /// @dev Match Uniswap v4 swap routing guide: `abi.encode(IV4Router.ExactInputSingleParams{...})`
    /// (https://docs.uniswap.org/contracts/v4/guides/swap-routing). `minHopPriceX36` is required by
    /// `IV4Router` / `CalldataDecoder.decodeSwapExactInSingleParams` even when the docs snippet omits it.
    function _v4SwapParamChunks(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minOut,
        bytes memory hookData
    ) private pure returns (bytes[] memory params) {
        params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                minHopPriceX36: 0,
                hookData: hookData
            })
        );
        Currency inC = zeroForOne ? key.currency0 : key.currency1;
        Currency outC = zeroForOne ? key.currency1 : key.currency0;
        params[1] = abi.encode(inC, uint256(amountIn));
        params[2] = abi.encode(outC, uint256(minOut));
    }

    function _v4SwapActionBytes() private pure returns (bytes memory) {
        return abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
    }

    function _ensureAllowance(IERC20 token, address spender, uint256 amount) internal {
        if (token.allowance(address(this), spender) < amount) {
            SafeERC20.forceApprove(token, spender, type(uint256).max);
        }
    }
}
