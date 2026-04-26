// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../contracts/FloatStrategy.sol";

/// @notice Documents behavior when `mode == OFFENSIVE` (enum value 2).
/// @dev `_enterOffensive()` sets `mode = Mode.OFFENSIVE` before rebalancing/mint, then on success keeps
///      OFFENSIVE and sets `baseTokenShareBps = offensiveTargetAssetBps` (policy). Drift checks use a
///      separate realized anchor inside the strategy. Clears floor/defensive anchors, bumps
///      `consecutiveOffensiveCount`, and emits `StrategyEvent` type 5. On failure it calls
///      `_enterDefensive()` (mode DEFENSIVE). OFFENSIVE shares LP rules with NORMAL via `_lpModeActive()`.
///      Tests that force OFFENSIVE via `stdstore` cover keeper/deposit edges without full pool setup.
contract FloatStrategyKeeperOffensiveTest is Test {
    using stdStorage for StdStorage;

    /// @dev `LiquidityLibrary.PositionState liqPos.positionId` — packed struct starts at storage slot 13
    ///      (`forge inspect FloatStrategy storageLayout`); first word is `positionId`.
    uint256 internal constant LIQ_POS_SLOT = 13;
    /// @dev Base WETH — immutable on `FloatStrategy`; local anvil has no bytecode here unless forked.
    address internal constant WETH_BASE = 0x4200000000000000000000000000000000000006;

    FloatStrategy internal strat;

    function _mockIdleBalancesZero() internal {
        bytes memory callData = abi.encodeCall(IERC20.balanceOf, (address(strat)));
        vm.mockCall(address(0), callData, abi.encode(uint256(0)));
        vm.mockCall(WETH_BASE, callData, abi.encode(uint256(0)));
    }

    function setUp() public {
        strat = new FloatStrategy();
        // Deliberately skip setUpContract: no pool/npm setup. positionId stays 0.
    }

    function test_keeperCheck_OFFENSIVE_noPosition_entersDefensive() public {
        stdstore.target(address(strat)).sig("mode()").checked_write(uint256(uint8(FloatStrategy.Mode.OFFENSIVE)));

        assertEq(uint256(strat.mode()), uint256(FloatStrategy.Mode.OFFENSIVE), "pre: OFFENSIVE");
        assertEq(strat.getPositionId(), 0, "pre: no NFT position");

        // Trailing floor: skipped (not NORMAL). _checkInRange: out of range + positionId==0 -> _enterDefensive.
        bool needUpkeep = strat.keeperCheck();

        assertTrue(needUpkeep, "keeper returns true (outOfRange path + tokenShare short-circuit)");
        assertEq(uint256(strat.mode()), uint256(FloatStrategy.Mode.DEFENSIVE), "post: DEFENSIVE");
        assertGt(strat.defensiveEnteredAt(), 0, "defensive timestamp set");
    }

    function test_keeperCheck_OFFENSIVE_noPosition_skipsTrailingFloor() public {
        stdstore.target(address(strat)).sig("mode()").checked_write(uint256(uint8(FloatStrategy.Mode.OFFENSIVE)));
        // If trailing floor ran with garbage baseline, these could drift; should stay 0 when not NORMAL.
        assertEq(strat.baselineTick(), 0);
        assertEq(strat.floorTick(), 0);

        strat.keeperCheck();

        // _checkTrailingPriceFloor early-outs; with positionId==0 it clears anchors (already 0).
        assertEq(strat.baselineTick(), 0);
        assertEq(strat.floorTick(), 0);
    }

    function test_keeperCheck_NORMAL_noPosition_entersDefensive_sameAsOffensiveForInRange() public {
        // Baseline: NORMAL + no position behaves the same on the in-range branch.
        assertEq(uint256(strat.mode()), uint256(FloatStrategy.Mode.NORMAL));
        assertEq(strat.getPositionId(), 0);

        bool needUpkeep = strat.keeperCheck();

        assertTrue(needUpkeep);
        assertEq(uint256(strat.mode()), uint256(FloatStrategy.Mode.DEFENSIVE));
    }

    /// @notice After OFFENSIVE + no NFT, `deposit` still hits `_deposit` first (positionId check) and exits
    ///         quietly when there are no idle tokens (no `StrategyEvent` 0).
    function test_deposit_OFFENSIVE_noPosition_idleEmpty_noop() public {
        _mockIdleBalancesZero();
        stdstore.target(address(strat)).sig("mode()").checked_write(uint256(uint8(FloatStrategy.Mode.OFFENSIVE)));

        strat.deposit(1);

        assertEq(uint256(strat.mode()), uint256(FloatStrategy.Mode.OFFENSIVE));
        assertEq(strat.getPositionId(), 0);
    }

    /// @notice OFFENSIVE + position routes like NORMAL into `_deposit()`; without npm/pool setup that reverts.
    function test_deposit_OFFENSIVE_withPosition_revertsWithoutFullSetup() public {
        stdstore.target(address(strat)).sig("mode()").checked_write(uint256(uint8(FloatStrategy.Mode.OFFENSIVE)));
        vm.store(address(strat), bytes32(LIQ_POS_SLOT), bytes32(uint256(1)));

        assertEq(strat.getPositionId(), 1);

        vm.expectRevert();
        strat.deposit(1);
    }

    /// @notice OFFENSIVE + no position: `_harvest` exits early (no NFT), but `harvestBoolean` still returns
    ///         `poolValue()` at the end — without `setUpContract` / pool, that final read reverts.
    function test_harvestBoolean_OFFENSIVE_noPosition_revertsOnPoolValueWithoutSetup() public {
        stdstore.target(address(strat)).sig("mode()").checked_write(uint256(uint8(FloatStrategy.Mode.OFFENSIVE)));

        vm.expectRevert();
        strat.harvestBoolean(false);
    }
}
