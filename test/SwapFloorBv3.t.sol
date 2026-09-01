// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {V3Deployments8453} from "../contracts/auto-vaults-base-v3/V3Deployments8453.sol";
import {AutoStrategyBv3} from "../contracts/auto-vaults-base-v3/AutoStrategyBv3.sol";
import {AutoStrategyManagerBv3} from "../contracts/auto-vaults-base-v3/AutoStrategyManagerBv3.sol";

contract FloorMockToken is ERC20 {
    constructor(string memory n) ERC20(n, n) {}
}

/// @dev Minimal v3 pool: spot comes from `slot0`, the TWAP from a `observe` cumulative built to yield an exact
///      mean tick. The two are set independently so a test can move spot while the TWAP stays put.
contract MockV3Pool {
    address public token0;
    address public token1;

    uint160 internal spotSqrt;
    int24 internal meanTick;
    bool internal observeReverts;

    function init(address t0, address t1) external {
        token0 = t0;
        token1 = t1;
    }

    function setSpotSqrt(uint160 s) external {
        spotSqrt = s;
    }

    function setMeanTick(int24 t) external {
        meanTick = t;
    }

    function setObserveReverts(bool b) external {
        observeReverts = b;
    }

    function fee() external pure returns (uint24) {
        return 3000;
    }

    function tickSpacing() external pure returns (int24) {
        return 60;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (spotSqrt, 0, 0, 0, 0, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity)
    {
        require(!observeReverts, "OLD");
        tickCumulatives = new int56[](2);
        secondsPerLiquidity = new uint160[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(meanTick) * int56(uint56(secondsAgos[0]));
    }
}

contract MockV3Factory {
    address public pool;

    function setPool(address p) external {
        pool = p;
    }

    function getPool(address, address, uint24) external view returns (address) {
        return pool;
    }
}

contract SwapFloorBv3Test is Test {
    AutoStrategyBv3 internal strategy;
    MockV3Pool internal pool;
    FloorMockToken internal asset;

    address internal constant WETH_ADDR = V3Deployments8453.WETH;
    address internal constant FACTORY_ADDR = V3Deployments8453.FACTORY;
    /// @dev sqrtPriceX96 for a 1:1 pool, i.e. tick 0.
    uint160 internal constant SQRT_1 = 79228162514264337593543950336;
    uint256 internal constant AMOUNT = 1_000 ether;

    function setUp() public {
        vm.etch(FACTORY_ADDR, type(MockV3Factory).runtimeCode);
        // `bootstrap` touches WETH, so the canonical address needs real token code behind it.
        vm.etch(WETH_ADDR, type(FloorMockToken).runtimeCode);

        pool = new MockV3Pool();
        // token0 == WETH keeps `_price1e18FromSqrt` on its non-inverted branch.
        asset = new FloorMockToken("ASSET");
        pool.init(WETH_ADDR, address(asset));
        pool.setSpotSqrt(SQRT_1);
        pool.setMeanTick(0);

        MockV3Factory(FACTORY_ADDR).setPool(address(pool));

        strategy = new AutoStrategyBv3(address(this));
        strategy.bootstrap(
            address(this), // owner, so this test can drive the manager setters
            address(0x1101), // vault
            address(0x1102), // swapRouter
            address(0x1103), // operatorRegistry
            address(0x1104), // keeper
            address(0x1105), // feeManager
            address(0x1106), // shareStaking
            address(asset),
            3000
        );
    }

    /// @dev sqrt scaled by `num/den`; price moves by the square of that ratio.
    function _scaledSqrt(uint256 num, uint256 den) internal pure returns (uint160) {
        return uint160((uint256(SQRT_1) * num) / den);
    }

    function test_DefaultSwapSlippageIsOnePercent() public view {
        assertEq(strategy.swapSlippageBps(), 100);
    }

    function test_FloorIsTwapMinusHaircut() public view {
        // 1:1 TWAP, 1% haircut.
        assertEq(strategy.minOutForSwap(WETH_ADDR, AMOUNT), 990 ether);
        assertEq(strategy.minOutForSwap(address(asset), AMOUNT), 990 ether);
    }

    /// @dev The heart of R3-QUOTE: moving spot inside the deviation band must not move the floor. A quote-derived
    ///      floor would track spot here, which is exactly what made the old router's bound worthless.
    function test_FloorDoesNotFollowManipulatedSpot() public {
        uint256 atRest = strategy.minOutForSwap(address(asset), AMOUNT);

        // ~2.01% price move (sqrt scaled by 1.01), inside the 300 bps band.
        pool.setSpotSqrt(_scaledSqrt(101, 100));
        assertEq(strategy.minOutForSwap(address(asset), AMOUNT), atRest);

        // Push spot the other way; the floor is still anchored to the unchanged TWAP.
        pool.setSpotSqrt(_scaledSqrt(99, 100));
        assertEq(strategy.minOutForSwap(address(asset), AMOUNT), atRest);
    }

    function test_FloorIsZeroWhenSpotLeavesTwapBand() public {
        // ~10.25% price move, well past the 300 bps default.
        pool.setSpotSqrt(_scaledSqrt(105, 100));
        assertEq(strategy.minOutForSwap(address(asset), AMOUNT), 0);
    }

    function test_FloorIsZeroWhenOracleUnavailable() public {
        pool.setObserveReverts(true);
        assertEq(strategy.minOutForSwap(address(asset), AMOUNT), 0);
    }

    /// @dev Disabling the oracle would zero every floor and so revert every withdrawal. Shortening the window is
    ///      the supported way to loosen the gate, so `0` must not be reachable.
    function test_TwapSecondsCannotBeDisabled() public {
        vm.expectRevert(AutoStrategyManagerBv3.TwapConfig.selector);
        strategy.setTwapSeconds(0);

        strategy.setTwapSeconds(60);
        assertEq(strategy.twapSeconds(), 60);
        assertGt(strategy.minOutForSwap(address(asset), AMOUNT), 0);
    }

    /// @dev The release valve for a frozen exit. A ~6.09% move (sqrt scaled by 1.03) is outside the 300 bps
    ///      default but inside the 1,000 bps cap, so widening the band restores withdrawals.
    function test_WideningBandRestoresFloorAfterSpotMove() public {
        pool.setSpotSqrt(_scaledSqrt(103, 100));
        assertEq(strategy.minOutForSwap(address(asset), AMOUNT), 0);

        strategy.setMaxTwapDeviationBps(1_000);
        assertGt(strategy.minOutForSwap(address(asset), AMOUNT), 0);
    }

    /// @dev The cap bounds the valve for rebalances: a move past 1,000 bps cannot be unblocked by widening.
    ///      Exits are not stuck at the same point, because they price against three times the band.
    function test_WideningBandCannotRescueExtremeMove() public {
        pool.setSpotSqrt(_scaledSqrt(105, 100)); // ~10.25%, past the 1,000 bps cap
        strategy.setMaxTwapDeviationBps(1_000);
        assertEq(strategy.minOutForSwap(address(asset), AMOUNT), 0);
        assertGt(strategy.minOutForWithdraw(address(asset), AMOUNT), 0);
    }

    // --- Withdraw release valve ---

    /// @dev A skipped rebalance retries next block, a blocked exit strands the user, so the two paths do not
    ///      share a tolerance. At the 300 bps default a ~6.09% move stops rebalancing but must not stop exits.
    function test_WithdrawBandIsThreeTimesRebalanceBand() public {
        pool.setSpotSqrt(_scaledSqrt(103, 100)); // ~609 bps: past 300, inside 900
        assertEq(strategy.minOutForSwap(address(asset), AMOUNT), 0);
        assertGt(strategy.minOutForWithdraw(address(asset), AMOUNT), 0);
    }

    /// @dev The wider band is still a band: 3x is a tolerance, not a bypass.
    function test_WithdrawBandStillBlocksExtremeMove() public {
        pool.setSpotSqrt(_scaledSqrt(105, 100)); // ~1,025 bps, past the 900 bps withdraw band
        assertEq(strategy.minOutForWithdraw(address(asset), AMOUNT), 0);
    }

    /// @dev Widening the band must not weaken pricing: the exit floor stays pinned to the TWAP even when spot
    ///      sits 6% away, so a sandwich cannot widen its own take by moving spot.
    function test_WithdrawFloorDoesNotFollowManipulatedSpot() public {
        uint256 atRest = strategy.minOutForWithdraw(address(asset), AMOUNT);
        assertEq(atRest, 990 ether);

        pool.setSpotSqrt(_scaledSqrt(103, 100));
        assertEq(strategy.minOutForWithdraw(address(asset), AMOUNT), atRest);

        pool.setSpotSqrt(_scaledSqrt(97, 100));
        assertEq(strategy.minOutForWithdraw(address(asset), AMOUNT), atRest);
    }

    /// @dev The 15% run that the 1,000 bps cap alone could not clear. Widening to the cap lifts the exit band to
    ///      3,000 bps, so withdrawals price through while rebalances stay gated.
    function test_WidenedBandClearsFifteenPercentRunForExits() public {
        pool.setSpotSqrt(_scaledSqrt(10_724, 10_000)); // sqrt(1.15), i.e. ~1,500 bps
        assertEq(strategy.minOutForWithdraw(address(asset), AMOUNT), 0);

        strategy.setMaxTwapDeviationBps(1_000);
        assertEq(strategy.minOutForSwap(address(asset), AMOUNT), 0);
        assertGt(strategy.minOutForWithdraw(address(asset), AMOUNT), 0);
    }

    function test_FloorTracksTwapWhenTwapMoves() public {
        uint256 atRest = strategy.minOutForSwap(address(asset), AMOUNT);
        // Move the TWAP itself and keep spot alongside it; the floor must follow.
        pool.setMeanTick(200);
        pool.setSpotSqrt(_scaledSqrt(101, 100));
        uint256 moved = strategy.minOutForSwap(address(asset), AMOUNT);
        assertTrue(moved != atRest);
        assertGt(moved, 0);
    }

    function test_WiderHaircutLowersFloor() public {
        strategy.setSwapSlippageBps(500);
        assertEq(strategy.minOutForSwap(WETH_ADDR, AMOUNT), 950 ether);
    }

    // --- R3-CONFIG caps ---

    function test_MaxTwapDeviationIsCapped() public {
        strategy.setMaxTwapDeviationBps(1_000);
        assertEq(strategy.maxTwapDeviationBps(), 1_000);

        vm.expectRevert(AutoStrategyManagerBv3.TwapConfig.selector);
        strategy.setMaxTwapDeviationBps(1_001);
    }

    function test_SwapSlippageIsCapped() public {
        strategy.setSwapSlippageBps(1_000);
        assertEq(strategy.swapSlippageBps(), 1_000);

        vm.expectRevert(AutoStrategyManagerBv3.TwapConfig.selector);
        strategy.setSwapSlippageBps(1_001);
    }
}
