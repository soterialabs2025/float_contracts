// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../contracts/FloatStrategy.sol";

/// @notice Documents OOR keeper edges when `mode == OFFENSIVE` without full v3 pool setup.
contract FloatStrategyKeeperOffensiveTest is Test {
    using stdStorage for StdStorage;

    uint256 internal constant LIQ_POS_SLOT = 14;
    address internal constant WETH_BASE = 0x4200000000000000000000000000000000000006;

    FloatStrategy internal strat;

    function _mockIdleBalancesZero() internal {
        bytes memory callData = abi.encodeCall(IERC20.balanceOf, (address(strat)));
        vm.mockCall(address(0), callData, abi.encode(uint256(0)));
        vm.mockCall(WETH_BASE, callData, abi.encode(uint256(0)));
    }

    function setUp() public {
        strat = new FloatStrategy();
    }

    function test_keeperCheck_OFFENSIVE_noPosition_noOp() public {
        stdstore.target(address(strat)).sig("mode()").checked_write(uint256(uint8(FloatStrategy.Mode.OFFENSIVE)));

        assertEq(uint256(strat.mode()), uint256(FloatStrategy.Mode.OFFENSIVE));
        assertEq(strat.getPositionId(), 0);

        bool needUpkeep = strat.keeperCheck();

        assertFalse(needUpkeep, "no position: keeper is no-op");
        assertEq(uint256(strat.mode()), uint256(FloatStrategy.Mode.OFFENSIVE));
    }

    function test_keeperCheck_NORMAL_noPosition_noOp() public {
        assertEq(uint256(strat.mode()), uint256(FloatStrategy.Mode.NORMAL));
        assertEq(strat.getPositionId(), 0);

        bool needUpkeep = strat.keeperCheck();

        assertFalse(needUpkeep);
        assertEq(uint256(strat.mode()), uint256(FloatStrategy.Mode.NORMAL));
    }

    function test_deposit_OFFENSIVE_noPosition_idleEmpty_noop() public {
        _mockIdleBalancesZero();
        stdstore.target(address(strat)).sig("mode()").checked_write(uint256(uint8(FloatStrategy.Mode.OFFENSIVE)));

        strat.deposit(1);

        assertEq(uint256(strat.mode()), uint256(FloatStrategy.Mode.OFFENSIVE));
        assertEq(strat.getPositionId(), 0);
    }

    function test_deposit_OFFENSIVE_withPosition_revertsWithoutFullSetup() public {
        stdstore.target(address(strat)).sig("mode()").checked_write(uint256(uint8(FloatStrategy.Mode.OFFENSIVE)));
        vm.store(address(strat), bytes32(LIQ_POS_SLOT), bytes32(uint256(1)));

        assertEq(strat.getPositionId(), 1);

        vm.expectRevert();
        strat.deposit(1);
    }

    function test_harvestBoolean_OFFENSIVE_noPosition_revertsOnPoolValueWithoutSetup() public {
        stdstore.target(address(strat)).sig("mode()").checked_write(uint256(uint8(FloatStrategy.Mode.OFFENSIVE)));

        vm.expectRevert();
        strat.harvestBoolean(false);
    }
}
