// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SwapGateLib} from "../contracts/auto-vault-rh-v4/libraries/SwapGateLib.sol";
import {AutoStrategyManagerRhV4} from "../contracts/auto-vault-rh-v4/AutoStrategyManagerRhV4.sol";

contract ManagerHarnessRh is AutoStrategyManagerRhV4 {}

/// @dev RhV4 twin of the fee coverage in SwapFeeFloorBv4/SwapTickGateBv4. The anchor gate is exercised there and
///      the library is otherwise identical, so this confirms the twin actually carries the fee deduction and the
///      separated swap tolerance rather than re-testing shared behaviour.
contract SwapFeeFloorRhV4Test is Test {
    uint160 internal constant SQRT_ONE = 79228162514264337593543950336;
    uint256 internal constant DIVISOR = 10_000;
    uint256 internal constant SLIPPAGE_BPS = 100;
    uint256 internal constant MAX_DEV = 2_000;
    uint24 internal constant NO_FEE = 0;
    uint24 internal constant FEE_ONE_PCT = 10_000;
    uint24 internal constant FEE_THIRTY_BIP = 3_000;

    ManagerHarnessRh internal m;

    function setUp() public {
        m = new ManagerHarnessRh();
        vm.roll(100);
        vm.warp(1_000_000);
    }

    function _anchor() internal view returns (SwapGateLib.Anchor memory) {
        return SwapGateLib.Anchor({
            tick: 0,
            has: true,
            time: uint64(block.timestamp) - 1 hours,
            blockNumber: uint64(block.number) - 1
        });
    }

    function _minOutWithFee(uint24 feePips) internal view returns (uint256) {
        return SwapGateLib.minOut(SQRT_ONE, 0, _anchor(), MAX_DEV, true, true, 1e18, SLIPPAGE_BPS, DIVISOR, feePips);
    }

    /// @dev What the pool actually pays for 1e18 in at parity, after taking `feePips` off the input.
    function _payable(uint24 feePips) internal pure returns (uint256) {
        return (1e18 * (1_000_000 - uint256(feePips))) / 1_000_000;
    }

    function test_FloorLeavesRoomForOnePercentPoolFee() public view {
        assertEq(_minOutWithFee(NO_FEE), _payable(FEE_ONE_PCT), "unfeed floor consumes the entire post-fee output");
        assertLt(_minOutWithFee(FEE_ONE_PCT), _payable(FEE_ONE_PCT), "fee-aware floor must sit below it");
    }

    function test_FloorIsQuoteMinusFeeThenSlippage() public view {
        assertEq(_minOutWithFee(FEE_ONE_PCT), 0.9801e18);
        assertEq(_minOutWithFee(FEE_THIRTY_BIP), 0.98703e18);
    }

    function testFuzz_FloorAlwaysSitsBelowPostFeeOutput(uint24 feePips) public view {
        feePips = uint24(bound(feePips, 0, 100_000));
        assertLe(_minOutWithFee(feePips), _payable(feePips));
    }

    function test_FullFeeQuotesNothing() public view {
        assertEq(_minOutWithFee(1_000_000), 0);
    }

    function test_ProtocolFeeCompoundsWithLpFee() public view {
        uint24 combined = ProtocolFeeLibrary.calculateSwapFee(1_000, FEE_ONE_PCT);
        assertEq(combined, 10_990);
        assertLt(_minOutWithFee(combined), _minOutWithFee(FEE_ONE_PCT));
        assertLe(_minOutWithFee(combined), _payable(combined));
    }

    function test_QuoteInvertsWithCurrencyOrder() public pure {
        uint160 sqrtFour = uint160(SQRT_ONE * 2);
        assertEq(SwapGateLib.quoteAtSqrt(sqrtFour, 1e18, true), 4e18);
        assertEq(SwapGateLib.quoteAtSqrt(sqrtFour, 1e18, false), 0.25e18);
    }

    function test_SpotPriceAtParityIsOne() public pure {
        assertEq(SwapGateLib.spotPrice1e18(SQRT_ONE, true), 1e18);
        assertEq(SwapGateLib.spotPrice1e18(SQRT_ONE, false), 1e18);
    }

    function test_SwapSlippageDefaultsToOnePercent() public view {
        assertEq(m.swapSlippageBps(), 100);
    }

    function test_SwapSlippageIsCapped() public {
        m.setSwapSlippageBps(1_000);
        assertEq(m.swapSlippageBps(), 1_000);
        vm.expectRevert(AutoStrategyManagerRhV4.SwapSlippageBps.selector);
        m.setSwapSlippageBps(1_001);
    }

    function test_SwapSlippageDoesNotMoveMintSlippage() public {
        uint16 mintBefore = m.slippageBps();
        m.setSwapSlippageBps(750);
        assertEq(m.slippageBps(), mintBefore);
    }
}
