// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./V3Deployments4663.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @dev Uniswap V3 SwapRouter02-style exactInputSingle (no deadline field).
interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @dev Settable V4 router the fee manager is authorized on (wire separately).
interface ISoteriaV4SwapRouter {
    function swapExactInputSingleStrict(address tokenIn, bool zeroForOne, uint128 amountIn)
        external
        returns (uint256 amountOut);
}

/// @title SoteriaFeeManagerRhV3
/// @notice Robinhood Chain (4663) fee manager: receives protocol fee tokens/ETH, swaps to WETH/USDG, forwards to treasury or partner.
/// @dev WETH = aeWETH. The `usdc` slot defaults to USDG (6 decimals) on RH; rename kept for Base API parity.
contract SoteriaFeeManagerRhV3 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Robinhood aeWETH (WETH9-compatible).
    IWETH public immutable WETH = IWETH(V3Deployments4663.WETH);

    /// @dev Robinhood USDG (6 decimals). Kept as `usdc` for API parity with Base SoteriaFeeManager.
    address internal constant DEFAULT_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    ISwapRouterV3 public v3SwapRouter;
    ISoteriaV4SwapRouter public v4SwapRouter;
    address public soteriaTreasury;
    address public soteriaRewards;
    address public soteriaPartner;
    IERC20 public usdc;
    uint24 public v3DefaultFee = 10000;

    mapping(address => bool) public operators;

    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error InvalidToken();
    error RouterNotSet();
    error EthTransferFailed();
    error AmountTooLarge();

    event OperatorUpdated(address indexed account, bool allowed);
    event ConfigUpdated(bytes32 indexed key, address value);
    event V3FeeUpdated(uint24 fee);
    event EthSaved(uint256 amount);
    event TokenSwappedToWeth(address indexed token, bool indexed usedV4, uint256 amountIn, uint256 amountOut);
    event EthSwappedToUsdc(uint256 amountIn, uint256 amountOut);
    event SentToTreasury(address indexed token, uint256 amount);
    event SentToPartner(address indexed tokenOrEth, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner() && !operators[msg.sender]) revert Unauthorized();
        _;
    }

    constructor(address initialOperator) Ownable(msg.sender) {
        usdc = IERC20(DEFAULT_USDG);
        v3SwapRouter = ISwapRouterV3(V3Deployments4663.SWAP_ROUTER02);
        if (initialOperator != address(0)) {
            operators[initialOperator] = true;
            emit OperatorUpdated(initialOperator, true);
        }
        emit ConfigUpdated("usdc", DEFAULT_USDG);
        emit ConfigUpdated("v3SwapRouter", V3Deployments4663.SWAP_ROUTER02);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Config
    // ─────────────────────────────────────────────────────────────────────────

    function addOperator(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        operators[account] = true;
        emit OperatorUpdated(account, true);
    }

    function removeOperator(address account) external onlyOwner {
        operators[account] = false;
        emit OperatorUpdated(account, false);
    }

    function setV3SwapRouter(address router) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        v3SwapRouter = ISwapRouterV3(router);
        emit ConfigUpdated("v3SwapRouter", router);
    }

    function setV4SwapRouter(address router) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        v4SwapRouter = ISoteriaV4SwapRouter(router);
        emit ConfigUpdated("v4SwapRouter", router);
    }

    function setSoteriaTreasury(address treasury) external onlyOwner {
        if (treasury == address(0)) revert ZeroAddress();
        soteriaTreasury = treasury;
        emit ConfigUpdated("soteriaTreasury", treasury);
    }

    function setSoteriaRewards(address rewards) external onlyOwner {
        if (rewards == address(0)) revert ZeroAddress();
        soteriaRewards = rewards;
        emit ConfigUpdated("soteriaRewards", rewards);
    }

    function setSoteriaPartner(address partner) external onlyOwner {
        if (partner == address(0)) revert ZeroAddress();
        soteriaPartner = partner;
        emit ConfigUpdated("soteriaPartner", partner);
    }

    /// @notice Set the stable used for treasury/partner sends and `swapEthToUsdcV3` (USDG by default on RH).
    function setUsdc(address usdc_) external onlyOwner {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        emit ConfigUpdated("usdc", usdc_);
    }

    function setV3DefaultFee(uint24 fee) external onlyOwner {
        if (fee == 0) revert ZeroAmount();
        v3DefaultFee = fee;
        emit V3FeeUpdated(fee);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ETH
    // ─────────────────────────────────────────────────────────────────────────

    receive() external payable {}

    /// @notice Wrap the contract's full ETH balance to WETH (aeWETH).
    function saveETH() external nonReentrant onlyOwnerOrOperator returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) revert ZeroAmount();
        WETH.deposit{value: amount}();
        emit EthSaved(amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Swaps (full balances)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Swap this contract's full `token` balance to WETH via the V3 router.
    function swapTokenToWethV3(address token) external nonReentrant onlyOwnerOrOperator returns (uint256 amountOut) {
        if (token == address(0) || token == address(WETH)) revert InvalidToken();
        if (address(v3SwapRouter) == address(0)) revert RouterNotSet();

        uint256 amountIn = IERC20(token).balanceOf(address(this));
        if (amountIn == 0) revert ZeroAmount();

        IERC20(token).forceApprove(address(v3SwapRouter), amountIn);
        amountOut = v3SwapRouter.exactInputSingle(
            ISwapRouterV3.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: address(WETH),
                fee: v3DefaultFee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        emit TokenSwappedToWeth(token, false, amountIn, amountOut);
    }

    /// @notice Swap this contract's full `token` balance to WETH via the settable V4 router.
    function swapTokenToWethV4(address token) external nonReentrant onlyOwnerOrOperator returns (uint256 amountOut) {
        if (token == address(0) || token == address(WETH)) revert InvalidToken();
        if (address(v4SwapRouter) == address(0)) revert RouterNotSet();

        uint256 amountIn = IERC20(token).balanceOf(address(this));
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > type(uint128).max) revert AmountTooLarge();

        // Pool ordering: currency0 < currency1. Selling token for WETH:
        // token < WETH ⇒ token is currency0 ⇒ zeroForOne = true.
        bool zeroForOne = uint160(token) < uint160(address(WETH));

        IERC20(token).forceApprove(address(v4SwapRouter), amountIn);
        amountOut = v4SwapRouter.swapExactInputSingleStrict(token, zeroForOne, uint128(amountIn));
        emit TokenSwappedToWeth(token, true, amountIn, amountOut);
    }

    /// @notice Wrap any ETH, then swap this contract's full WETH balance to USDG (or configured stable) via V3.
    function swapEthToUsdcV3() external nonReentrant onlyOwnerOrOperator returns (uint256 amountOut) {
        if (address(v3SwapRouter) == address(0)) revert RouterNotSet();
        if (address(usdc) == address(0)) revert ZeroAddress();

        uint256 ethBal = address(this).balance;
        if (ethBal > 0) {
            WETH.deposit{value: ethBal}();
        }

        uint256 amountIn = WETH.balanceOf(address(this));
        if (amountIn == 0) revert ZeroAmount();

        IERC20(address(WETH)).forceApprove(address(v3SwapRouter), amountIn);
        amountOut = v3SwapRouter.exactInputSingle(
            ISwapRouterV3.ExactInputSingleParams({
                tokenIn: address(WETH),
                tokenOut: address(usdc),
                fee: v3DefaultFee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        emit EthSwappedToUsdc(amountIn, amountOut);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outbound
    // ─────────────────────────────────────────────────────────────────────────

    /// @param asUsdc true → send full USDG/stable balance; false → send full WETH balance.
    function sendToTreasury(bool asUsdc) external nonReentrant onlyOwnerOrOperator returns (uint256 amount) {
        if (soteriaTreasury == address(0)) revert ZeroAddress();
        if (asUsdc) {
            amount = usdc.balanceOf(address(this));
            if (amount == 0) revert ZeroAmount();
            usdc.safeTransfer(soteriaTreasury, amount);
            emit SentToTreasury(address(usdc), amount);
        } else {
            amount = WETH.balanceOf(address(this));
            if (amount == 0) revert ZeroAmount();
            IERC20(address(WETH)).safeTransfer(soteriaTreasury, amount);
            emit SentToTreasury(address(WETH), amount);
        }
    }

    /// @param asUsdc true → send full USDG/stable balance; false → send full native ETH balance.
    function sendToPartner(bool asUsdc) external nonReentrant onlyOwnerOrOperator returns (uint256 amount) {
        if (soteriaPartner == address(0)) revert ZeroAddress();
        if (asUsdc) {
            amount = usdc.balanceOf(address(this));
            if (amount == 0) revert ZeroAmount();
            usdc.safeTransfer(soteriaPartner, amount);
            emit SentToPartner(address(usdc), amount);
        } else {
            amount = address(this).balance;
            if (amount == 0) revert ZeroAmount();
            (bool ok,) = soteriaPartner.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
            emit SentToPartner(address(0), amount);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Rescue
    // ─────────────────────────────────────────────────────────────────────────

    function rescueETH(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit Rescued(address(0), to, amount);
    }

    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}
