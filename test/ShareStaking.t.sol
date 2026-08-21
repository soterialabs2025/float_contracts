// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ShareStaking} from "../contracts/auto-vaults-rh-v3/ShareStaking.sol";
import {LiquidShares} from "../contracts/auto-vaults-rh-v3/LiquidShares.sol";
import {V3Deployments4663} from "../contracts/auto-vaults-rh-v3/V3Deployments4663.sol";
import {IAutoSwapRouterV3} from "../contracts/auto-vaults-rh-v3/interfaces/IAutoSwapRouterV3.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Pulls `tokenIn`, pays 1:1 WETH to caller (enough for epoch reward tests).
contract MockSwapRouter is IAutoSwapRouterV3 {
    address public immutable weth;

    constructor(address weth_) {
        weth = weth_;
    }

    function addAuthorizedStrategy(address) external {}

    function swapExactInputSingleStrict(address tokenIn, address tokenOut, uint24, uint128 amountIn)
        external
        returns (uint256 amountOut)
    {
        require(tokenOut == weth, "out");
        amountOut = uint256(amountIn);
        ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(weth).mint(msg.sender, amountOut);
    }
}

/// @dev Reverting router to exercise soft-fail ASSET→WETH path.
contract RevertingSwapRouter is IAutoSwapRouterV3 {
    function addAuthorizedStrategy(address) external {}

    function swapExactInputSingleStrict(address, address, uint24, uint128) external pure returns (uint256) {
        revert("swap failed");
    }
}

contract ShareStakingTest is Test {
    address internal constant WETH = V3Deployments4663.WETH;

    ShareStaking internal staking;
    LiquidShares internal aLS;
    MockERC20 internal asset;
    MockSwapRouter internal router;

    address internal strategy = address(0xBEEF);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint24 internal constant POOL_FEE = 3000;

    function setUp() public {
        // ShareStaking immutably binds RH WETH — etch a mintable ERC20 at that address.
        MockERC20 wethImpl = new MockERC20("WETH", "WETH");
        vm.etch(WETH, address(wethImpl).code);

        asset = new MockERC20("ASSET", "ASSET");
        router = new MockSwapRouter(WETH);

        aLS = new LiquidShares();
        aLS.bootstrap(address(this)); // this test contract mints liquid shares

        staking = new ShareStaking();
        staking.bootstrap(address(this), address(aLS), strategy, address(asset), address(router), POOL_FEE);

        aLS.mint(alice, 100 ether);
        aLS.mint(bob, 100 ether);

        vm.prank(alice);
        aLS.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        aLS.approve(address(staking), type(uint256).max);
    }

    function _warpToEpochEnd(uint256 epoch) internal {
        vm.warp(staking.epochEnd(epoch));
    }

    function _notifyWeth(uint256 amount) internal {
        MockERC20(WETH).mint(address(staking), amount);
        vm.prank(strategy);
        staking.notifyReward(WETH, amount);
    }

    function test_stake_locksUntilEpochEnd() public {
        vm.prank(alice);
        staking.stake(10 ether);

        assertEq(staking.stakedBalance(alice), 10 ether);
        assertEq(staking.lockedUntil(alice), staking.epochEnd(0));

        vm.prank(alice);
        vm.expectRevert(ShareStaking.EpochExitLocked.selector);
        staking.unstake(10 ether);

        _warpToEpochEnd(0);

        vm.prank(alice);
        staking.unstake(10 ether);

        assertEq(staking.stakedBalance(alice), 0);
        assertEq(aLS.balanceOf(alice), 100 ether);
    }

    function test_notifyAndClaim_afterWarp() public {
        vm.prank(alice);
        staking.stake(10 ether);

        _notifyWeth(1 ether);
        assertEq(staking.epochRewardWeth(0), 1 ether);
        assertEq(staking.currentEpoch(), 0);

        _warpToEpochEnd(0);

        // claim checkpoints + finalizes epoch 0
        vm.prank(alice);
        uint256 got = staking.claim(0);

        assertEq(got, 1 ether);
        assertTrue(staking.epochFinalized(0));
        assertEq(staking.currentEpoch(), 1);
        assertEq(MockERC20(WETH).balanceOf(alice), 1 ether);
        assertTrue(staking.epochClaimed(alice, 0));
    }

    function test_twoStakers_proRataByTimeWeight() public {
        // Alice stakes full epoch; Bob joins halfway → Alice ~2x Bob weight.
        vm.prank(alice);
        staking.stake(10 ether);

        uint256 mid = staking.epochStart(0) + staking.EPOCH_DURATION() / 2;
        vm.warp(mid);

        vm.prank(bob);
        staking.stake(10 ether);

        _notifyWeth(3 ether);
        _warpToEpochEnd(0);

        vm.prank(alice);
        uint256 aliceGot = staking.claim(0);
        vm.prank(bob);
        uint256 bobGot = staking.claim(0);

        // Alice staked twice as long at same size → ~2/3 of pot (allow 1 wei dust).
        assertApproxEqAbs(aliceGot, 2 ether, 1);
        assertApproxEqAbs(bobGot, 1 ether, 1);
        assertEq(aliceGot + bobGot, 3 ether);
    }

    function test_assetSwapSoftFail_doesNotRevert_andLeavesAsset() public {
        RevertingSwapRouter bad = new RevertingSwapRouter();
        ShareStaking s2 = new ShareStaking();
        s2.bootstrap(address(this), address(aLS), strategy, address(asset), address(bad), POOL_FEE);

        asset.mint(address(s2), 5 ether);
        vm.prank(strategy);
        s2.notifyReward(address(asset), 5 ether);

        assertEq(s2.epochRewardWeth(0), 0);
        assertEq(asset.balanceOf(address(s2)), 5 ether);
    }

    function test_ownerCut_pendingPull_afterPackageLock() public {
        address tba = address(0x7BA);
        staking.transferOwnershipFromFactory(tba);
        assertTrue(staking.ownershipLocked());

        vm.prank(tba);
        staking.setOwnerRewardBps(1000); // 10%
        vm.prank(tba);
        staking.setOwnerRewardRecipient(tba);

        vm.prank(alice);
        staking.stake(10 ether);
        _notifyWeth(10 ether);
        _warpToEpochEnd(0);

        // Finalize via alice claim path
        vm.prank(alice);
        uint256 aliceGot = staking.claim(0);

        assertEq(staking.pendingOwnerReward(tba), 1 ether);
        assertEq(aliceGot, 9 ether);

        vm.prank(tba);
        uint256 ownerGot = staking.claimOwnerReward();
        assertEq(ownerGot, 1 ether);
        assertEq(MockERC20(WETH).balanceOf(tba), 1 ether);
    }

    function test_restake_relocksThroughNewEpoch() public {
        vm.prank(alice);
        staking.stake(10 ether);
        _warpToEpochEnd(0);

        vm.prank(alice);
        staking.unstake(10 ether);

        // New stake in epoch 1 locks through epoch 1 end
        vm.prank(alice);
        staking.stake(5 ether);
        assertEq(staking.currentEpoch(), 1);
        assertEq(staking.lockedUntil(alice), staking.epochEnd(1));

        vm.prank(alice);
        vm.expectRevert(ShareStaking.EpochExitLocked.selector);
        staking.unstake(5 ether);
    }
}
