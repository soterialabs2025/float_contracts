// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {V3Deployments8453} from "../contracts/auto-vaults-base-v3/V3Deployments8453.sol";
import {AutoSwapRouterBv3} from "../contracts/auto-vaults-base-v3/AutoSwapRouterBv3.sol";
import {IUniswapRouter} from "../contracts/auto-vaults-base-v3/interfaces/IUniswapRouter.sol";

contract MockToken is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stands in for SwapRouter02 at its hardcoded address. Enforces `amountOutMinimum` the way the real
///      router does, so the caller-supplied floor is what the tests actually exercise.
contract MockSwapRouter02 {
    uint256 public amountOut;

    function setAmountOut(uint256 out) external {
        amountOut = out;
    }

    function exactInputSingle(IUniswapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256)
    {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        uint256 out = amountOut;
        require(out >= p.amountOutMinimum, "Too little received");
        MockToken(p.tokenOut).mint(p.recipient, out);
        return out;
    }
}

contract AutoSwapRouterBv3Test is Test {
    AutoSwapRouterBv3 internal router;
    MockSwapRouter02 internal uni;
    MockToken internal asset;
    MockToken internal weth;

    address internal constant UNI_ADDR = V3Deployments8453.SWAP_ROUTER02;
    uint128 internal constant AMOUNT_IN = 1_000 ether;
    uint24 internal constant FEE = 3000;

    function setUp() public {
        vm.etch(UNI_ADDR, type(MockSwapRouter02).runtimeCode);
        uni = MockSwapRouter02(UNI_ADDR);

        asset = new MockToken("ASSET");
        weth = new MockToken("WETH");

        router = new AutoSwapRouterBv3();
        router.addAuthorizedStrategy(address(this));

        asset.mint(address(this), 1_000_000 ether);
        asset.approve(address(router), type(uint256).max);
    }

    function _swap(uint128 amountIn, uint256 minOut, uint256 deadline) internal returns (uint256) {
        return router.swapExactInputSingleStrict(
            address(asset), address(weth), FEE, amountIn, minOut, deadline
        );
    }

    /// @dev The core of R3-QUOTE: the router must refuse to invent a floor for the caller.
    function test_RevertsOnZeroMinOut() public {
        uni.setAmountOut(AMOUNT_IN);
        vm.expectRevert(AutoSwapRouterBv3.ZeroMinOut.selector);
        _swap(AMOUNT_IN, 0, 0);
    }

    function test_RevertsOnZeroAmountIn() public {
        vm.expectRevert(AutoSwapRouterBv3.ZeroAmount.selector);
        _swap(0, 1, 0);
    }

    function test_RevertsOnExpiredDeadline() public {
        uni.setAmountOut(AMOUNT_IN);
        vm.warp(1_000);
        vm.expectRevert(AutoSwapRouterBv3.Expired.selector);
        _swap(AMOUNT_IN, 1, block.timestamp - 1);
    }

    function test_ZeroDeadlineDisablesExpiryCheck() public {
        uni.setAmountOut(AMOUNT_IN);
        vm.warp(1_000_000);
        assertEq(_swap(AMOUNT_IN, 1, 0), AMOUNT_IN);
    }

    function test_CallerFloorIsPassedThroughToUniswap() public {
        uni.setAmountOut(900 ether);
        vm.expectRevert(bytes("Too little received"));
        _swap(AMOUNT_IN, 950 ether, 0);
    }

    function test_SwapCreditsRecipientAndLeavesNoResidue() public {
        uni.setAmountOut(990 ether);
        uint256 before = asset.balanceOf(address(this));
        assertEq(_swap(AMOUNT_IN, 950 ether, 0), 990 ether);
        assertEq(before - asset.balanceOf(address(this)), AMOUNT_IN);
        assertEq(weth.balanceOf(address(this)), 990 ether);
        assertEq(asset.balanceOf(address(router)), 0);
    }

    function test_UnauthorizedCallerReverts() public {
        uni.setAmountOut(AMOUNT_IN);
        vm.prank(address(0xBEEF));
        vm.expectRevert(AutoSwapRouterBv3.Unauthorized.selector);
        router.swapExactInputSingleStrict(address(asset), address(weth), FEE, AMOUNT_IN, 1, 0);
    }

    function test_RevokedStrategyCannotSwap() public {
        uni.setAmountOut(AMOUNT_IN);
        assertEq(_swap(AMOUNT_IN, 1, 0), AMOUNT_IN);

        router.removeAuthorizedStrategy(address(this));
        assertFalse(router.isAuthorizedStrategy(address(this)));

        vm.expectRevert(AutoSwapRouterBv3.Unauthorized.selector);
        _swap(AMOUNT_IN, 1, 0);
    }

    function test_RemoveUnauthorizedStrategyReverts() public {
        vm.expectRevert(AutoSwapRouterBv3.NotAuthorized.selector);
        router.removeAuthorizedStrategy(address(0xBEEF));
    }

    function test_RescueRecoversStrandedTokens() public {
        asset.mint(address(router), 5 ether);
        router.rescue(address(asset), address(0xCAFE), 5 ether);
        assertEq(asset.balanceOf(address(0xCAFE)), 5 ether);
    }

    function test_RescueOnlyOwner() public {
        asset.mint(address(router), 5 ether);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        router.rescue(address(asset), address(0xBEEF), 5 ether);
    }
}
