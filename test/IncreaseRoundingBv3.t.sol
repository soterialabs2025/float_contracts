// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiquidityLibraryV2} from "../contracts/auto-vaults-base-v3/libraries/LiquidityLibraryV2.sol";
import {INonfungiblePositionManager} from "../contracts/auto-vaults-base-v3/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3PoolMinimal} from "../contracts/auto-vaults-base-v3/interfaces/IUniswapV3PoolMinimal.sol";
import {TickMath} from "../contracts/auto-vaults-base-v3/libraries/TickMath.sol";

contract RoundingToken is ERC20 {
    constructor() ERC20("T", "T") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract RoundingMockPool {
    uint160 internal _sqrtP;
    int24 internal _tick;

    function set(int24 tick) external {
        _tick = tick;
        _sqrtP = TickMath.getSqrtRatioAtTick(tick);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (_sqrtP, _tick, 0, 1, 1, 0, true);
    }

    function tickSpacing() external pure returns (int24) {
        return 200;
    }
}

/// @dev Stands in for the NonfungiblePositionManager with the one behaviour that matters here: it recomputes
///      liquidity from the amounts it is handed and, like `UniswapV3Pool.mint`, refuses zero with a bare `require`.
///      That bare require is why the live failures carried no revert data.
contract RoundingMockNpm {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickLower;
    int24 public tickUpper;
    RoundingMockPool public pool;

    uint256 public calls;
    uint256 public lastAmount0;
    uint256 public lastAmount1;

    constructor(address t0, address t1, uint24 f, int24 lower, int24 upper, RoundingMockPool p) {
        token0 = t0;
        token1 = t1;
        fee = f;
        tickLower = lower;
        tickUpper = upper;
        pool = p;
    }

    function positions(uint256)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        return (0, address(0), token0, token1, fee, tickLower, tickUpper, 1e18, 0, 0, 0, 0);
    }

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata p)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        calls++;
        lastAmount0 = p.amount0Desired;
        lastAmount1 = p.amount1Desired;
        (uint160 sqrtP,,,,,,) = pool.slot0();
        (uint160 sqrtL, uint160 sqrtU) = LiquidityLibraryV2.getSqrtRatios(tickLower, tickUpper);
        liquidity = LiquidityLibraryV2.getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, p.amount0Desired, p.amount1Desired);
        // UniswapV3Pool.mint: `require(amount > 0);` — no message, no data.
        require(liquidity > 0);
        return (liquidity, p.amount0Desired, p.amount1Desired);
    }
}

/// @dev Owns the PositionState the library mutates, the way a strategy does.
contract RoundingHarness {
    LiquidityLibraryV2.PositionState internal liqPos;

    constructor(uint256 id, int24 lower, int24 upper) {
        liqPos.positionId = id;
        liqPos.tickLower = lower;
        liqPos.tickUpper = upper;
    }

    function increase(LiquidityLibraryV2.IncreaseContext memory ctx, IERC20 t0, IERC20 t1, uint256 max0, uint256 max1)
        external
        returns (uint128)
    {
        return LiquidityLibraryV2.increaseLiquidityInternal(liqPos, ctx, t0, t1, max0, max1);
    }
}

/// @dev Reproduces the live Bv3 and Sv3 keeper reverts. Both vaults held a large ASSET balance and 1 wei of WETH
///      against an in-range position. The library's zero-liquidity guard runs on liquidity derived from the
///      balances, where 1 wei prices to a non-zero number; the amounts derived back from that liquidity round the
///      WETH leg to zero, and the position manager then recomputes zero liquidity from those amounts and reverts.
///      The check has to sit on the amounts actually sent, which is what this test pins.
contract IncreaseRoundingBv3Test is Test {
    // Sv3 at block 61,615,000: pool tick -164556, position [-165400, -163800], ~2.7e22 ASSET and 1 wei of WETH.
    // The library priced the wei to ~91,600 liquidity and sent `increaseLiquidity(12_554_379, 0)`.
    int24 internal constant POOL_TICK = -164556;
    int24 internal constant LOWER = -165400;
    int24 internal constant UPPER = -163800;
    uint256 internal constant ASSET_BAL = 2.7e22;
    uint256 internal constant DUST = 1e12;

    RoundingToken internal asset;
    RoundingToken internal weth;
    RoundingMockPool internal pool;
    RoundingMockNpm internal npm;
    RoundingHarness internal h;

    function setUp() public {
        asset = new RoundingToken();
        weth = new RoundingToken();
        // token0 must sort below token1; force the ordering rather than depend on deployment addresses.
        if (address(asset) > address(weth)) (asset, weth) = (weth, asset);
        pool = new RoundingMockPool();
        pool.set(POOL_TICK);
        npm = new RoundingMockNpm(address(asset), address(weth), 10_000, LOWER, UPPER, pool);
        h = new RoundingHarness(12_732, LOWER, UPPER);
    }

    function _ctx() internal view returns (LiquidityLibraryV2.IncreaseContext memory) {
        return LiquidityLibraryV2.IncreaseContext({
            npm: INonfungiblePositionManager(address(npm)),
            pool: IUniswapV3PoolMinimal(address(pool)),
            fee: 10_000,
            slippageBps: 100,
            dust: DUST
        });
    }

    /// @dev The live failure. Must not reach the position manager at all: a wei of one leg cannot fund an in-range
    ///      add, and the caller should learn that as a zero return rather than a revert it cannot read.
    function test_OneWeiLegDoesNotReachThePositionManager() public {
        asset.mint(address(h), ASSET_BAL);
        weth.mint(address(h), 1);

        uint128 added = h.increase(_ctx(), IERC20(address(asset)), IERC20(address(weth)), ASSET_BAL, 1);

        assertEq(added, 0, "nothing can be added");
        assertEq(npm.calls(), 0, "the manager must not be asked to mint zero");
    }

    /// @dev Same balances, price below the range. Now only token0 is needed, so a zero WETH leg is the correct
    ///      shape of the add and it must still go through. The fix has to distinguish these two cases.
    function test_BelowRangeSingleSidedAddStillProceeds() public {
        pool.set(LOWER - 1_000);
        asset.mint(address(h), ASSET_BAL);
        weth.mint(address(h), 1);

        uint128 added = h.increase(_ctx(), IERC20(address(asset)), IERC20(address(weth)), ASSET_BAL, 1);

        assertGt(added, 0);
        assertEq(npm.calls(), 1);
        assertGt(npm.lastAmount0(), 0);
        assertEq(npm.lastAmount1(), 0);
    }

    /// @dev Both legs funded, in range: the ordinary path is untouched.
    function test_TwoSidedInRangeAddProceeds() public {
        asset.mint(address(h), ASSET_BAL);
        weth.mint(address(h), 1e18);

        uint128 added = h.increase(_ctx(), IERC20(address(asset)), IERC20(address(weth)), ASSET_BAL, 1e18);

        assertGt(added, 0);
        assertEq(npm.calls(), 1);
        assertGt(npm.lastAmount0(), 0);
        assertGt(npm.lastAmount1(), 0);
    }

    /// @dev Whatever the leg sizes, if the library decides to call the manager the manager must be able to mint.
    ///      This is the property the live vaults violated.
    function testFuzz_AnyAddThatIsAttemptedCanBeMinted(uint96 bal0, uint96 bal1, int24 tickOffset) public {
        tickOffset = int24(bound(tickOffset, -3_000, 3_000));
        pool.set(POOL_TICK + tickOffset);
        asset.mint(address(h), bal0);
        weth.mint(address(h), bal1);

        // The mock manager reverts bare on zero liquidity, so reaching here means either it was never called or
        // it minted successfully. Both are correct; a bare revert is the failure.
        h.increase(_ctx(), IERC20(address(asset)), IERC20(address(weth)), bal0, bal1);
    }
}
