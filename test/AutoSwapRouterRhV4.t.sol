// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "../lib/v4-core/src/types/Currency.sol";
import {SwapParams} from "../lib/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "../lib/v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "../lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {V4Deployments4663} from "../contracts/auto-vault-rh-v4/V4Deployments4663.sol";
import {AutoSwapRouterRhV4} from "../contracts/auto-vault-rh-v4/AutoSwapRouterRhV4.sol";
import {IAutoSwapRouterRhV4} from "../contracts/auto-vault-rh-v4/interfaces/IAutoSwapRouterRhV4.sol";

contract MockTokenRh is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stands in for the v4 PoolManager at its hardcoded address; `extsload` ignores the slot key.
contract MockPoolManagerRh {
    bytes32 internal _slot0;
    uint128 public owedAmt;
    uint128 public receivedAmt;

    function setSlot0(uint160 sqrtPriceX96) external {
        _slot0 = bytes32(uint256(sqrtPriceX96));
    }

    function setSwapResult(uint128 owed_, uint128 received_) external {
        owedAmt = owed_;
        receivedAmt = received_;
    }

    function extsload(bytes32) external view returns (bytes32) {
        return _slot0;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey memory, SwapParams memory params, bytes calldata) external view returns (BalanceDelta) {
        return params.zeroForOne
            ? toBalanceDelta(-int128(owedAmt), int128(receivedAmt))
            : toBalanceDelta(int128(receivedAmt), -int128(owedAmt));
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(Currency currency, address to, uint256 amount) external {
        address token = Currency.unwrap(currency);
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "eth");
        } else {
            IERC20(token).transfer(to, amount);
        }
    }

    receive() external payable {}
}

contract AutoSwapRouterRhV4Test is Test {
    AutoSwapRouterRhV4 internal router;
    MockPoolManagerRh internal pm;
    MockTokenRh internal asset;

    address internal constant PM_ADDR = V4Deployments4663.POOL_MANAGER;
    uint160 internal constant SQRT_1 = 79228162514264337593543950336;
    uint128 internal constant AMOUNT_IN = 100 ether;

    function setUp() public {
        vm.etch(PM_ADDR, type(MockPoolManagerRh).runtimeCode);
        pm = MockPoolManagerRh(payable(PM_ADDR));
        pm.setSlot0(SQRT_1);

        asset = new MockTokenRh("ASSET");
        router = new AutoSwapRouterRhV4();
        router.addAuthorizedStrategy(address(this));

        asset.mint(PM_ADDR, 1_000_000 ether);
        vm.deal(address(this), 10_000 ether);
    }

    /// @dev Native ETH is currency0; selling ETH is zeroForOne.
    function _key() internal view returns (IAutoSwapRouterRhV4.AutoPoolKey memory) {
        return IAutoSwapRouterRhV4.AutoPoolKey({
            currency0: address(0),
            currency1: address(asset),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
    }

    function _sellEth(uint128 amountIn, uint128 minOut, uint256 deadline) internal returns (uint256) {
        return router.swapExactInputSingleStrict{value: amountIn}(true, amountIn, minOut, deadline, _key(), "");
    }

    function test_RevertsOnZeroMinOut() public {
        pm.setSwapResult(AMOUNT_IN, AMOUNT_IN);
        vm.expectRevert(AutoSwapRouterRhV4.ZeroMinOut.selector);
        _sellEth(AMOUNT_IN, 0, 0);
    }

    function test_RevertsOnExpiredDeadline() public {
        pm.setSwapResult(AMOUNT_IN, AMOUNT_IN);
        vm.warp(1_000);
        vm.expectRevert(AutoSwapRouterRhV4.Expired.selector);
        _sellEth(AMOUNT_IN, 1, block.timestamp - 1);
    }

    function test_RevertsWhenOutputBelowMin() public {
        pm.setSwapResult(AMOUNT_IN, 90 ether);
        vm.expectRevert(AutoSwapRouterRhV4.InsufficientOutput.selector);
        _sellEth(AMOUNT_IN, 95 ether, 0);
    }

    function test_SellEthFullFill() public {
        pm.setSwapResult(AMOUNT_IN, 99 ether);
        uint256 ethBefore = address(this).balance;
        uint256 out = _sellEth(AMOUNT_IN, 95 ether, 0);
        assertEq(out, 99 ether);
        assertEq(asset.balanceOf(address(this)), 99 ether);
        assertEq(ethBefore - address(this).balance, AMOUNT_IN);
    }

    function test_RefundsPartialFillEthResidue() public {
        pm.setSwapResult(60 ether, 60 ether);
        uint256 ethBefore = address(this).balance;
        _sellEth(AMOUNT_IN, 50 ether, 0);
        // Only the consumed 60 leaves the caller; the 40 residue is returned.
        assertEq(ethBefore - address(this).balance, 60 ether);
        assertEq(address(router).balance, 0);
    }

    /// @dev The old implementation swept `address(this).balance`, handing pre-existing router ETH to whoever
    ///      swapped next. The refund must be scoped to this swap's own residue.
    function test_DonatedEthIsNotSweptToCaller() public {
        vm.deal(address(router), 5 ether);
        pm.setSwapResult(60 ether, 60 ether);

        uint256 ethBefore = address(this).balance;
        _sellEth(AMOUNT_IN, 50 ether, 0);

        assertEq(ethBefore - address(this).balance, 60 ether);
        assertEq(address(router).balance, 5 ether, "donated ETH must stay put");
    }

    function test_RescueRecoversDonatedEth() public {
        vm.deal(address(router), 5 ether);
        router.rescue(address(0), address(0xCAFE), 5 ether);
        assertEq(address(0xCAFE).balance, 5 ether);
        assertEq(address(router).balance, 0);
    }

    function test_RevokedStrategyCannotSwap() public {
        router.removeAuthorizedStrategy(address(this));
        vm.prank(address(0xBEEF));
        vm.expectRevert(AutoSwapRouterRhV4.Unauthorized.selector);
        router.swapExactInputSingleStrict(true, AMOUNT_IN, 1, 0, _key(), "");
    }

    function test_EthValueMustMatchAmountIn() public {
        pm.setSwapResult(AMOUNT_IN, AMOUNT_IN);
        vm.expectRevert(AutoSwapRouterRhV4.ZeroAmount.selector);
        router.swapExactInputSingleStrict{value: 1 ether}(true, AMOUNT_IN, 1, 0, _key(), "");
    }

    receive() external payable {}
}
