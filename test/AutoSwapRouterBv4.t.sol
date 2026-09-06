// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {V4Deployments8453} from "../contracts/v4/V4Deployments8453.sol";
import {AutoSwapRouterBv4} from "../contracts/auto-vault-base-v4/AutoSwapRouterBv4.sol";
import {IAutoSwapRouterBv4} from "../contracts/auto-vault-base-v4/interfaces/IAutoSwapRouterBv4.sol";

contract MockToken is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stands in for the v4 PoolManager at its hardcoded address. `extsload` ignores the slot key and returns a
///      configurable slot0 so StateLibrary.getSlot0 resolves without modelling real pool storage.
contract MockPoolManager {
    bytes32 internal _slot0;
    uint128 public owedAmt;
    uint128 public receivedAmt;
    uint160 public postSwapSqrt;

    function setSlot0(uint160 sqrtPriceX96) external {
        _slot0 = bytes32(uint256(sqrtPriceX96));
    }

    function setSwapResult(uint128 owed_, uint128 received_) external {
        owedAmt = owed_;
        receivedAmt = received_;
    }

    function setPostSwapSqrt(uint160 sqrtPriceX96) external {
        postSwapSqrt = sqrtPriceX96;
    }

    function extsload(bytes32) external view returns (bytes32) {
        return _slot0;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey memory, SwapParams memory params, bytes calldata) external returns (BalanceDelta) {
        if (postSwapSqrt != 0) _slot0 = bytes32(uint256(postSwapSqrt));
        return params.zeroForOne
            ? toBalanceDelta(-int128(owedAmt), int128(receivedAmt))
            : toBalanceDelta(int128(receivedAmt), -int128(owedAmt));
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(Currency currency, address to, uint256 amount) external {
        IERC20(Currency.unwrap(currency)).transfer(to, amount);
    }

    receive() external payable {}
}

contract AutoSwapRouterBv4Test is Test {
    AutoSwapRouterBv4 internal router;
    MockPoolManager internal pm;
    MockToken internal asset;
    MockToken internal weth;

    address internal constant PM_ADDR = V4Deployments8453.POOL_MANAGER;
    uint160 internal constant SQRT_1 = 79228162514264337593543950336; // 1:1
    uint128 internal constant AMOUNT_IN = 1_000 ether;

    function setUp() public {
        vm.etch(PM_ADDR, type(MockPoolManager).runtimeCode);
        pm = MockPoolManager(payable(PM_ADDR));
        pm.setSlot0(SQRT_1);

        asset = new MockToken("ASSET");
        weth = new MockToken("WETH");

        router = new AutoSwapRouterBv4();
        router.addAuthorizedStrategy(address(this));

        asset.mint(address(this), 1_000_000 ether);
        asset.approve(address(router), type(uint256).max);
        // The PoolManager pays the output leg out of its own balance via `take`.
        weth.mint(PM_ADDR, 1_000_000 ether);
    }

    function _key() internal view returns (IAutoSwapRouterBv4.AutoPoolKey memory) {
        (address c0, address c1) = address(asset) < address(weth)
            ? (address(asset), address(weth))
            : (address(weth), address(asset));
        return IAutoSwapRouterBv4.AutoPoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
    }

    function _zeroForOne() internal view returns (bool) {
        return address(asset) < address(weth);
    }

    function _swap(uint128 amountIn, uint128 minOut, uint256 deadline) internal returns (uint256) {
        return router.swapExactInputSingleStrict(_zeroForOne(), amountIn, minOut, deadline, _key(), "");
    }

    function test_RevertsOnZeroMinOut() public {
        pm.setSwapResult(AMOUNT_IN, AMOUNT_IN);
        vm.expectRevert(AutoSwapRouterBv4.ZeroMinOut.selector);
        _swap(AMOUNT_IN, 0, 0);
    }

    function test_RevertsOnExpiredDeadline() public {
        pm.setSwapResult(AMOUNT_IN, AMOUNT_IN);
        vm.warp(1_000);
        vm.expectRevert(AutoSwapRouterBv4.Expired.selector);
        _swap(AMOUNT_IN, 1, block.timestamp - 1);
    }

    function test_ZeroDeadlineDisablesExpiryCheck() public {
        pm.setSwapResult(AMOUNT_IN, AMOUNT_IN);
        vm.warp(1_000_000);
        assertEq(_swap(AMOUNT_IN, 1, 0), AMOUNT_IN);
    }

    function test_RevertsWhenOutputBelowMin() public {
        pm.setSwapResult(AMOUNT_IN, 900 ether);
        vm.expectRevert(AutoSwapRouterBv4.InsufficientOutput.selector);
        _swap(AMOUNT_IN, 950 ether, 0);
    }

    function test_AmountOutIsPoolDeltaNotBalanceDelta() public {
        pm.setSwapResult(AMOUNT_IN, 990 ether);
        uint256 before = weth.balanceOf(address(this));
        uint256 out = _swap(AMOUNT_IN, 950 ether, 0);
        assertEq(out, 990 ether);
        assertEq(weth.balanceOf(address(this)) - before, 990 ether);
    }

    /// @dev A donation to the recipient mid-swap must not count toward the output floor.
    function test_DonationDoesNotInflateAmountOut() public {
        pm.setSwapResult(AMOUNT_IN, 900 ether);
        weth.mint(address(this), 100 ether);
        vm.expectRevert(AutoSwapRouterBv4.InsufficientOutput.selector);
        _swap(AMOUNT_IN, 950 ether, 0);
    }

    function test_RefundsPartialFillResidue() public {
        // Pool consumes only 600 of the 1000 supplied.
        pm.setSwapResult(600 ether, 600 ether);
        uint256 before = asset.balanceOf(address(this));
        _swap(AMOUNT_IN, 500 ether, 0);
        // Net asset spend is the amount actually swapped; the 400 residue comes back.
        assertEq(before - asset.balanceOf(address(this)), 600 ether);
        assertEq(asset.balanceOf(address(router)), 0);
    }

    function test_FullFillLeavesNoResidue() public {
        pm.setSwapResult(AMOUNT_IN, AMOUNT_IN);
        uint256 before = asset.balanceOf(address(this));
        _swap(AMOUNT_IN, 1, 0);
        assertEq(before - asset.balanceOf(address(this)), AMOUNT_IN);
        assertEq(asset.balanceOf(address(router)), 0);
    }

    function test_RevokedStrategyCannotSwap() public {
        pm.setSwapResult(AMOUNT_IN, AMOUNT_IN);
        assertEq(_swap(AMOUNT_IN, 1, 0), AMOUNT_IN);

        router.removeAuthorizedStrategy(address(this));
        assertFalse(router.isAuthorizedStrategy(address(this)));

        vm.prank(address(0xBEEF));
        vm.expectRevert(AutoSwapRouterBv4.Unauthorized.selector);
        router.swapExactInputSingleStrict(_zeroForOne(), AMOUNT_IN, 1, 0, _key(), "");
    }

    function test_RemoveUnauthorizedStrategyReverts() public {
        vm.expectRevert(AutoSwapRouterBv4.NotAuthorized.selector);
        router.removeAuthorizedStrategy(address(0xBEEF));
    }

    function test_UnauthorizedCallerReverts() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(AutoSwapRouterBv4.Unauthorized.selector);
        router.swapExactInputSingleStrict(_zeroForOne(), AMOUNT_IN, 1, 0, _key(), "");
    }

    function test_SetMaxPriceImpactBpsBounds() public {
        router.setMaxPriceImpactBps(500);
        assertEq(router.maxPriceImpactBps(), 500);

        vm.expectRevert(AutoSwapRouterBv4.BadSlippage.selector);
        router.setMaxPriceImpactBps(0);

        vm.expectRevert(AutoSwapRouterBv4.BadSlippage.selector);
        router.setMaxPriceImpactBps(5_001);
    }

    /// @dev The bound is direction-aware, and token address ordering decides `zeroForOne`, so the move has to be
    ///      pushed the way this swap would actually push it.
    function _movedSqrt(uint256 bps) internal view returns (uint160) {
        uint256 factor = _zeroForOne() ? 10_000 - bps : 10_000 + bps;
        return uint160((uint256(SQRT_1) * factor) / 10_000);
    }

    function test_PriceImpactBoundRejectsLargeMove() public {
        pm.setSwapResult(AMOUNT_IN, AMOUNT_IN);
        // 1000 bps of sqrt movement, well past the 200 bps default.
        pm.setPostSwapSqrt(_movedSqrt(1_000));
        vm.expectRevert(bytes("price impact"));
        _swap(AMOUNT_IN, 1, 0);
    }

    function test_PriceImpactBoundAllowsSmallMove() public {
        pm.setSwapResult(AMOUNT_IN, AMOUNT_IN);
        // 100 bps of sqrt movement, inside the 200 bps default.
        pm.setPostSwapSqrt(_movedSqrt(100));
        assertEq(_swap(AMOUNT_IN, 1, 0), AMOUNT_IN);
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
