// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ShareStakingBv3} from "../contracts/auto-vaults-base-v3/ShareStakingBv3.sol";
import {LiquidSharesBv3} from "../contracts/auto-vaults-base-v3/LiquidSharesBv3.sol";
import {V3Deployments8453} from "../contracts/auto-vaults-base-v3/V3Deployments8453.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stands in for AutoStrategyBv3: ShareStakingBv3 staticcalls `minOutForSwap` on the bootstrapped
///      strategy, so the strategy address has to be a contract even when only the WETH path is exercised.
contract MockStrategy {
    uint256 public floor;

    function setFloor(uint256 f) external {
        floor = f;
    }

    function minOutForSwap(address, uint256) external view returns (uint256) {
        return floor;
    }
}

/// @notice Covers the three ShareStakingBv3 audit findings and the two hardening items added with them.
///         The test contract plays the factory (so it may call `bootstrap`) and the vault (so it may mint
///         LiquidShares), which is how the production factory wires the package.
contract ShareStakingBv3AuditTest is Test {
    address internal constant WETH = V3Deployments8453.WETH;
    uint24 internal constant POOL_FEE = 10000;

    ShareStakingBv3 internal staking;
    LiquidSharesBv3 internal shares;
    MockERC20 internal asset;
    MockStrategy internal strategy;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal router = address(0x9007E4);

    function setUp() public {
        // ShareStakingBv3 immutably binds the Base WETH address; etch a mintable ERC20 there.
        MockERC20 wethImpl = new MockERC20("WETH", "WETH");
        vm.etch(WETH, address(wethImpl).code);

        asset = new MockERC20("ASSET", "ASSET");
        strategy = new MockStrategy();

        shares = new LiquidSharesBv3(address(this));
        shares.bootstrap(address(this));

        staking = new ShareStakingBv3(address(this));
        staking.bootstrap(address(this), address(shares), address(strategy), address(asset), router, POOL_FEE);
        staking.activate();

        shares.mint(alice, 100 ether);
        shares.mint(bob, 100 ether);

        vm.prank(alice);
        shares.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        shares.approve(address(staking), type(uint256).max);
    }

    /// @dev Funds the active epoch the way the strategy does: transfer first, then notify.
    function _fundWeth(uint256 amount) internal {
        MockERC20(WETH).mint(address(staking), amount);
        vm.prank(address(strategy));
        staking.notifyReward(WETH, amount);
    }

    /// @dev The accounting invariant the audit asserts: the liability counter equals the sum of live pots.
    function _assertAccountingConsistent(uint256 upToEpoch) internal view {
        uint256 sum;
        for (uint256 e; e <= upToEpoch; ++e) {
            sum += staking.epochRewardWeth(e);
        }
        assertEq(staking.accountedWeth(), sum, "accountedWeth != sum of epoch pots");
        assertLe(staking.accountedWeth(), MockERC20(WETH).balanceOf(address(staking)), "accounted exceeds balance");
    }

    // --- Finding 1: rewards funded into an epoch with zero stake-time ---

    function test_zeroWeightEpoch_rollsPotForward_insteadOfStranding() public {
        // Nobody staked in epoch 0, but a harvest funds it.
        _fundWeth(1 ether);
        assertEq(staking.epochRewardWeth(0), 1 ether);

        vm.warp(staking.epochEnd(0));
        staking.advance();

        // Epoch 0 closed with no claimable weight, so its pot moved to epoch 1 rather than being burned.
        assertTrue(staking.epochFinalized(0));
        assertEq(staking.epochTotalWeight(0), 0);
        assertEq(staking.epochRewardWeth(0), 0, "pot stranded in zero-weight epoch");
        assertEq(staking.epochRewardWeth(1), 1 ether, "pot did not roll forward");
        assertEq(staking.accountedWeth(), 1 ether, "roll-forward must not change the liability total");

        // A staker who arrives in epoch 1 can claim the carried pot in full.
        vm.prank(alice);
        staking.stake(10 ether);
        vm.warp(staking.epochEnd(1));

        vm.prank(alice);
        uint256 got = staking.claim(1);

        assertEq(got, 1 ether);
        assertEq(MockERC20(WETH).balanceOf(alice), 1 ether);
        assertEq(staking.accountedWeth(), 0);
    }

    function test_zeroWeightEpochs_chainRollForwardAcrossManyEpochs() public {
        _fundWeth(3 ether);

        // Five consecutive empty epochs: the pot should follow the chain, not fall out of it.
        vm.warp(staking.epochEnd(4));
        staking.advance();

        assertEq(staking.currentEpoch(), 5);
        for (uint256 e; e < 5; ++e) {
            assertEq(staking.epochRewardWeth(e), 0, "pot left behind in an empty epoch");
        }
        assertEq(staking.epochRewardWeth(5), 3 ether);
        _assertAccountingConsistent(5);
    }

    /// @dev `notifyReward` is not gated by `whenActive` while `stake` is, so a harvest between deployment and
    ///      `activate()` used to fund an epoch in which nobody was permitted to create stake-time.
    function test_fundingBeforeActivation_isNotLost() public {
        ShareStakingBv3 s2 = new ShareStakingBv3(address(this));
        s2.bootstrap(address(this), address(shares), address(strategy), address(asset), router, POOL_FEE);
        // Deliberately not activated yet.

        MockERC20(WETH).mint(address(s2), 2 ether);
        vm.prank(address(strategy));
        s2.notifyReward(WETH, 2 ether);

        vm.warp(s2.epochEnd(0));
        s2.activate();

        vm.prank(alice);
        shares.approve(address(s2), type(uint256).max);
        vm.prank(alice);
        s2.stake(10 ether);

        vm.warp(s2.epochEnd(1));
        vm.prank(alice);
        uint256 got = s2.claim(1);

        assertEq(got, 2 ether, "pre-activation harvest was burned");
    }

    /// @dev A zero-weight epoch defers the owner cut with the pot instead of taking a cut nobody can match.
    function test_rollForward_defersOwnerCutToThePayingEpoch() public {
        address tba = address(0x7BA);
        staking.transferOwnershipFromFactory(tba);
        vm.prank(tba);
        staking.setOwnerRewardBps(1000); // 10%
        vm.prank(tba);
        staking.setOwnerRewardRecipient(tba);

        _fundWeth(10 ether);
        vm.warp(staking.epochEnd(0));
        staking.advance();

        // Empty epoch took no cut.
        assertEq(staking.pendingOwnerReward(tba), 0);
        assertEq(staking.epochRewardWeth(1), 10 ether);

        vm.prank(alice);
        staking.stake(10 ether);
        vm.warp(staking.epochEnd(1));
        vm.prank(alice);
        uint256 got = staking.claim(1);

        // Cut is taken once, on the epoch that actually pays.
        assertEq(staking.pendingOwnerReward(tba), 1 ether);
        assertEq(got, 9 ether);
    }

    // --- Finding 3: unbacked WETH notifications ---

    function test_notifyWethWithoutTransfer_reverts() public {
        vm.prank(alice);
        staking.stake(10 ether);

        // Strategy claims 5 WETH it never sent.
        vm.prank(address(strategy));
        vm.expectRevert(ShareStakingBv3.UnbackedReward.selector);
        staking.notifyReward(WETH, 5 ether);

        assertEq(staking.accountedWeth(), 0);
        assertEq(staking.epochRewardWeth(0), 0);
    }

    /// @dev The audit's exact scenario: a later epoch's fake pot must not be able to spend the WETH that is
    ///      physically backing an already-finalized epoch.
    function test_replayedNotify_cannotDrainAnEarlierEpochsBacking() public {
        vm.prank(alice);
        staking.stake(10 ether);

        _fundWeth(100 ether); // genuinely funded epoch 0
        vm.warp(staking.epochEnd(0));
        staking.advance();
        assertEq(staking.epochRewardWeth(0), 100 ether);

        vm.prank(bob);
        staking.stake(10 ether);

        // Re-notify the same 100 WETH the contract already holds for epoch 0.
        vm.prank(address(strategy));
        vm.expectRevert(ShareStakingBv3.UnbackedReward.selector);
        staking.notifyReward(WETH, 100 ether);

        // Epoch 0's claimant is still fully backed.
        vm.prank(alice);
        uint256 got = staking.claim(0);
        assertEq(got, 100 ether);
        assertEq(MockERC20(WETH).balanceOf(alice), 100 ether);
    }

    function test_honestNotify_stillSucceeds() public {
        vm.prank(alice);
        staking.stake(10 ether);
        _fundWeth(4 ether);

        assertEq(staking.epochRewardWeth(0), 4 ether);
        _assertAccountingConsistent(0);
    }

    // --- Finding 2: epoch backlog and per-epoch claim cost ---

    function test_advance_isPermissionless() public {
        vm.warp(staking.epochEnd(0));

        vm.prank(bob); // not owner, not strategy, not a staker
        staking.advance();

        assertTrue(staking.epochFinalized(0));
        assertEq(staking.currentEpoch(), 1);
    }

    function test_claimMany_settlesSeveralEpochsInOneTransfer() public {
        vm.prank(alice);
        staking.stake(10 ether);

        _fundWeth(1 ether); // epoch 0
        vm.warp(staking.epochEnd(0));
        _fundWeth(1 ether); // finalizes 0, credits epoch 1
        vm.warp(staking.epochEnd(1));
        _fundWeth(1 ether); // finalizes 1, credits epoch 2
        vm.warp(staking.epochEnd(2));

        uint256[] memory epochs = new uint256[](3);
        epochs[0] = 0;
        epochs[1] = 1;
        epochs[2] = 2;

        vm.prank(alice);
        uint256 got = staking.claimMany(epochs);

        assertEq(got, 3 ether);
        assertEq(MockERC20(WETH).balanceOf(alice), 3 ether);
        assertEq(staking.accountedWeth(), 0);
    }

    /// @dev Skipping (rather than reverting on) empty entries is what lets a caller pass a whole range.
    function test_claimMany_skipsAlreadyClaimedAndEmptyEpochs() public {
        vm.prank(alice);
        staking.stake(10 ether);

        _fundWeth(1 ether);
        vm.warp(staking.epochEnd(0));
        _fundWeth(1 ether);
        vm.warp(staking.epochEnd(1));
        staking.advance();

        vm.prank(alice);
        staking.claim(0);

        uint256[] memory epochs = new uint256[](4);
        epochs[0] = 0; // already claimed
        epochs[1] = 1;
        epochs[2] = 2; // not finalized
        epochs[3] = 99; // never existed

        vm.prank(alice);
        uint256 got = staking.claimMany(epochs);

        assertEq(got, 1 ether, "only epoch 1 should have paid");
    }

    function test_claimMany_revertsWhenNothingPays() public {
        vm.warp(staking.epochEnd(0));
        staking.advance();

        uint256[] memory epochs = new uint256[](1);
        epochs[0] = 0;

        vm.prank(alice);
        vm.expectRevert(ShareStakingBv3.NothingToClaim.selector);
        staking.claimMany(epochs);
    }

    /// @dev `claim` must keep its original, more specific reverts.
    function test_claim_preservesOriginalErrors() public {
        vm.prank(alice);
        staking.stake(10 ether);
        _fundWeth(1 ether);

        vm.prank(alice);
        vm.expectRevert(ShareStakingBv3.EpochNotEnded.selector);
        staking.claim(0);

        vm.warp(staking.epochEnd(0));
        vm.prank(alice);
        staking.claim(0);

        vm.prank(alice);
        vm.expectRevert(ShareStakingBv3.AlreadyClaimed.selector);
        staking.claim(0);
    }

    // --- Hardening: surplus-only rescue ---

    function test_rescue_takesSurplusButNotStakerRewards() public {
        vm.prank(alice);
        staking.stake(10 ether);
        _fundWeth(1 ether); // accounted, must stay

        // Unsolicited donation on top of the accounted pot.
        MockERC20(WETH).mint(address(staking), 5 ether);

        staking.rescueToken(WETH, bob, 5 ether);
        assertEq(MockERC20(WETH).balanceOf(bob), 5 ether);

        // Nothing left above accountedWeth.
        vm.expectRevert(ShareStakingBv3.NothingToRescue.selector);
        staking.rescueToken(WETH, bob, 1);

        // The staker's pot survived and still pays out.
        vm.warp(staking.epochEnd(0));
        vm.prank(alice);
        assertEq(staking.claim(0), 1 ether);
    }

    function test_rescue_cannotTakeStakedShares() public {
        vm.prank(alice);
        staking.stake(10 ether);

        vm.expectRevert(ShareStakingBv3.NothingToRescue.selector);
        staking.rescueToken(address(shares), bob, 1);

        // Only a donation above totalStaked is reachable.
        uint256 bobBefore = shares.balanceOf(bob);
        shares.mint(address(staking), 2 ether);
        staking.rescueToken(address(shares), bob, 2 ether);
        assertEq(shares.balanceOf(bob) - bobBefore, 2 ether);
        assertEq(staking.totalStaked(), 10 ether);
        assertEq(shares.balanceOf(address(staking)), 10 ether, "staked principal must remain");
    }

    function test_rescue_recoversUnpriceableAssetRewards() public {
        // ASSET whose swap floor is unavailable is stranded by design; rescue is its only exit.
        asset.mint(address(staking), 7 ether);
        staking.rescueToken(address(asset), bob, 7 ether);
        assertEq(asset.balanceOf(bob), 7 ether);
    }

    function test_rescue_onlyOwner() public {
        MockERC20(WETH).mint(address(staking), 1 ether);
        vm.prank(bob);
        vm.expectRevert();
        staking.rescueToken(WETH, bob, 1 ether);
    }

    // --- Regressions on the behaviour the fixes touch ---

    function test_proRataWeightingUnchanged() public {
        vm.prank(alice);
        staking.stake(10 ether);

        vm.warp(staking.epochStart(0) + staking.EPOCH_DURATION() / 2);
        vm.prank(bob);
        staking.stake(10 ether);

        _fundWeth(3 ether);
        vm.warp(staking.epochEnd(0));

        vm.prank(alice);
        uint256 aliceGot = staking.claim(0);
        vm.prank(bob);
        uint256 bobGot = staking.claim(0);

        assertApproxEqAbs(aliceGot, 2 ether, 1);
        assertApproxEqAbs(bobGot, 1 ether, 1);
        assertEq(aliceGot + bobGot, 3 ether);
    }

    function test_stakeStillLocksUntilEpochEnd() public {
        vm.prank(alice);
        staking.stake(10 ether);
        assertEq(staking.lockedUntil(alice), staking.epochEnd(0));

        vm.prank(alice);
        vm.expectRevert(ShareStakingBv3.EpochExitLocked.selector);
        staking.unstake(10 ether);

        vm.warp(staking.epochEnd(0));
        vm.prank(alice);
        staking.unstake(10 ether);
        assertEq(shares.balanceOf(alice), 100 ether);
    }

    /// @dev Weight accrued while staked must survive the roll-forward branch untouched.
    function test_weightAccrualUnaffectedByRollForwardBranch() public {
        vm.prank(alice);
        staking.stake(10 ether);
        vm.warp(staking.epochEnd(0));
        staking.advance();

        uint256 expected = 10 ether * staking.EPOCH_DURATION();
        assertEq(staking.epochTotalWeight(0), expected);

        vm.prank(alice);
        staking.checkpoint();
        assertEq(staking.userEpochWeight(alice, 0), expected);
    }
}
