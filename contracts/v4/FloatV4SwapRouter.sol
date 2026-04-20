// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import "./interfaces/ISwapRouterV4.sol";
import "./interfaces/IFloatV4StrategySwapRouter.sol";

/// @title FloatV4SwapRouter
/// @notice Float-facing router: token → WETH via Universal Router `V4_SWAP` (see Uniswap v4 swap routing guide).
contract FloatV4SwapRouter is ISwapRouterV4, IFloatV4StrategySwapRouter, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniversalRouter public immutable universalRouter;
    IAllowanceTransfer public immutable permit2;
    IV4Quoter public immutable quoterV4;
    IERC20 public immutable WETH;

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
    error NoV4Pool();

    constructor(
        address universalRouter_,
        address permit2_,
        address quoterV4_,
        address weth_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (universalRouter_ == address(0) || permit2_ == address(0) || weth_ == address(0) || initialOwner == address(0)) {
            revert ZeroAddress();
        }
        universalRouter = IUniversalRouter(universalRouter_);
        permit2 = IAllowanceTransfer(permit2_);
        quoterV4 = IV4Quoter(quoterV4_);
        WETH = IERC20(weth_);
    }

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

        uint128 minOut = _minOut(key, zeroForOne, uint128(amountIn), minOutIfNoQuoter);

        address ur = address(universalRouter);
        _ensureAllowance(tokenIn, address(permit2), amountIn);
        permit2.approve(address(tokenIn), ur, uint160(amountIn), uint48(block.timestamp + 300));

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4SwapPayload(key, zeroForOne, uint128(amountIn), minOut);

        uint256 balBefore = tokenOut.balanceOf(address(this));
        IUniversalRouter(ur).execute(commands, inputs, block.timestamp + 300);
        amountOut = tokenOut.balanceOf(address(this)) - balBefore;
        if (amountOut > 0) {
            tokenOut.safeTransfer(msg.sender, amountOut);
        }
    }

    /// @inheritdoc ISwapRouterV4
    function swapToWethViaUniversalRouterV4(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        uint128 minOutIfNoQuoter
    ) external override nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > type(uint160).max) revert ZeroAmount();
        if (tokenIn == address(WETH)) revert TokenIsWETH();
        if (recipient == address(0)) revert ZeroAddress();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint24[3] memory fees = [uint24(500), uint24(3000), uint24(10000)];
        for (uint256 i = 0; i < fees.length; i++) {
            uint256 bal = IERC20(tokenIn).balanceOf(address(this));
            if (bal == 0) break;
            try this._swapExactInSingleFeeV4(tokenIn, bal, recipient, fees[i], minOutIfNoQuoter) returns (uint256 out) {
                if (out > 0) {
                    emit SwapExecuted(msg.sender, recipient, tokenIn, bal, out);
                    return out;
                }
            } catch {}
        }
        revert NoV4Pool();
    }

    /// @dev Self-call only; isolates per-fee try/catch.
    function _swapExactInSingleFeeV4(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        uint24 fee,
        uint128 minOutIfNoQuoter
    ) external returns (uint256 amountOut) {
        require(msg.sender == address(this), "only self");
        require(amountIn <= type(uint128).max, "amount");

        (address c0addr, address c1addr) = tokenIn < address(WETH) ? (tokenIn, address(WETH)) : (address(WETH), tokenIn);
        bool zeroForOne = tokenIn == c0addr;
        int24 tickSpacing = _feeToTickSpacing(fee);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0addr),
            currency1: Currency.wrap(c1addr),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        uint128 minOut = _minOut(key, zeroForOne, uint128(amountIn), minOutIfNoQuoter);

        address ur = address(universalRouter);
        _ensureAllowance(IERC20(tokenIn), address(permit2), amountIn);
        permit2.approve(tokenIn, ur, uint160(amountIn), uint48(block.timestamp + 300));

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4SwapPayload(key, zeroForOne, uint128(amountIn), minOut);

        uint256 balBefore = WETH.balanceOf(recipient);
        IUniversalRouter(ur).execute(commands, inputs, block.timestamp + 300);
        amountOut = WETH.balanceOf(recipient) - balBefore;
    }

    function _minOut(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minOutIfNoQuoter)
        internal
        returns (uint128 minOut)
    {
        address q = address(quoterV4);
        if (q == address(0)) {
            return minOutIfNoQuoter;
        }
        try quoterV4.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: amountIn, hookData: bytes("")
            })
        ) returns (uint256 quotedOut, uint256) {
            if (quotedOut == 0) minOut = minOutIfNoQuoter;
            else minOut = uint128(Math.mulDiv(quotedOut, 10_000 - uint256(defaultSlippageBps), 10_000));
        } catch {
            minOut = minOutIfNoQuoter;
        }
    }

    function _encodeV4SwapPayload(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minOut)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        Currency inC = zeroForOne ? key.currency0 : key.currency1;
        Currency outC = zeroForOne ? key.currency1 : key.currency0;
        params[1] = abi.encode(inC, uint256(amountIn));
        params[2] = abi.encode(outC, uint256(minOut));
        return abi.encode(actions, params);
    }

    function _feeToTickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10_000) return 200;
        revert("fee tier");
    }

    function _ensureAllowance(IERC20 token, address spender, uint256 amount) internal {
        if (token.allowance(address(this), spender) < amount) {
            SafeERC20.forceApprove(token, spender, type(uint256).max);
        }
    }
}
