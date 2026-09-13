// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {V3Deployments8453} from "../contracts/auto-vaults-base-v3/V3Deployments8453.sol";
import {AutoStrategyBv3} from "../contracts/auto-vaults-base-v3/AutoStrategyBv3.sol";
import {LiquidityLibraryV2} from "../contracts/auto-vaults-base-v3/libraries/LiquidityLibraryV2.sol";
import {INonfungiblePositionManager} from "../contracts/auto-vaults-base-v3/interfaces/INonfungiblePositionManager.sol";
import {TickMath} from "../contracts/auto-vaults-base-v3/libraries/TickMath.sol";

contract BoundedToken is ERC20 {
    constructor() ERC20("T", "T") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @dev Spot and TWAP set independently, both as ticks. 1% fee tier, 200 spacing, like the live pools.
contract BoundedPool {
    address public token0;
    address public token1;
    uint160 internal sqrtP;
    int24 internal tick;
    int24 internal meanTick;

    function init(address t0, address t1) external {
        token0 = t0;
        token1 = t1;
    }

    function setTick(int24 t) external {
        tick = t;
        sqrtP = TickMath.getSqrtRatioAtTick(t);
    }

    function setMeanTick(int24 t) external {
        meanTick = t;
    }

    function fee() external pure returns (uint24) {
        return 10_000;
    }

    function tickSpacing() external pure returns (int24) {
        return 200;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtP, tick, 0, 1, 1, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity)
    {
        tickCumulatives = new int56[](2);
        secondsPerLiquidity = new uint160[](2);
        tickCumulatives[1] = int56(meanTick) * int56(uint56(secondsAgos[0]));
    }
}

contract BoundedFactory {
    address public pool;

    function setPool(address p) external {
        pool = p;
    }

    function getPool(address, address, uint24) external view returns (address) {
        return pool;
    }
}

/// @dev Position manager with the pool's arithmetic and the pool's refusal: liquidity is recomputed from the
///      amounts handed in, zero reverts with no data, tokens move for real. Counts every call so a test can
///      say exactly how much work a keeper pass did.
contract BoundedNpm {
    struct Pos {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
    }

    BoundedPool public pool;
    // Etched code starts with empty storage, so ids are pre-incremented: the first position is 1, never 0.
    uint256 public lastId;
    mapping(uint256 => Pos) internal pos;

    uint256 public mints;
    uint256 public increases;
    uint256 public decreases;

    function setPool(BoundedPool p) external {
        pool = p;
    }

    function positions(uint256 id)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        Pos storage p = pos[id];
        return (0, address(0), p.token0, p.token1, p.fee, p.tickLower, p.tickUpper, p.liquidity, 0, 0, p.owed0, p.owed1);
    }

    function _liqAndAmounts(int24 lower, int24 upper, uint256 a0, uint256 a1)
        internal
        view
        returns (uint128 liq, uint256 n0, uint256 n1)
    {
        (uint160 sqrtP,,,,,,) = pool.slot0();
        (uint160 sqrtL, uint160 sqrtU) = LiquidityLibraryV2.getSqrtRatios(lower, upper);
        liq = LiquidityLibraryV2.getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, a0, a1);
        // UniswapV3Pool.mint: `require(amount > 0);`
        require(liq > 0);
        (n0, n1) = LiquidityLibraryV2.getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liq);
        // The pool rounds what it takes for an add up; the desired amounts are the ceiling it never exceeds.
        if (n0 < a0) n0 += 1;
        if (n1 < a1) n1 += 1;
    }

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        returns (uint256 id, uint128 liq, uint256 n0, uint256 n1)
    {
        mints++;
        (liq, n0, n1) = _liqAndAmounts(p.tickLower, p.tickUpper, p.amount0Desired, p.amount1Desired);
        require(n0 >= p.amount0Min && n1 >= p.amount1Min, "Price slippage check");
        IERC20(p.token0).transferFrom(msg.sender, address(this), n0);
        IERC20(p.token1).transferFrom(msg.sender, address(this), n1);
        id = ++lastId;
        pos[id] = Pos(p.token0, p.token1, p.fee, p.tickLower, p.tickUpper, liq, 0, 0);
    }

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata p)
        external
        returns (uint128 liq, uint256 n0, uint256 n1)
    {
        increases++;
        Pos storage s = pos[p.tokenId];
        (liq, n0, n1) = _liqAndAmounts(s.tickLower, s.tickUpper, p.amount0Desired, p.amount1Desired);
        require(n0 >= p.amount0Min && n1 >= p.amount1Min, "Price slippage check");
        IERC20(s.token0).transferFrom(msg.sender, address(this), n0);
        IERC20(s.token1).transferFrom(msg.sender, address(this), n1);
        s.liquidity += liq;
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata p)
        external
        returns (uint256 n0, uint256 n1)
    {
        decreases++;
        Pos storage s = pos[p.tokenId];
        require(p.liquidity > 0 && p.liquidity <= s.liquidity);
        (uint160 sqrtP,,,,,,) = pool.slot0();
        (uint160 sqrtL, uint160 sqrtU) = LiquidityLibraryV2.getSqrtRatios(s.tickLower, s.tickUpper);
        (n0, n1) = LiquidityLibraryV2.getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, p.liquidity);
        s.liquidity -= p.liquidity;
        s.owed0 += uint128(n0);
        s.owed1 += uint128(n1);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata p) external returns (uint256 n0, uint256 n1) {
        Pos storage s = pos[p.tokenId];
        n0 = s.owed0 < p.amount0Max ? s.owed0 : p.amount0Max;
        n1 = s.owed1 < p.amount1Max ? s.owed1 : p.amount1Max;
        s.owed0 -= uint128(n0);
        s.owed1 -= uint128(n1);
        if (n0 > 0) _pay(s.token0, p.recipient, n0);
        if (n1 > 0) _pay(s.token1, p.recipient, n1);
    }

    /// @dev This stands in for the whole pool, whose inventory rebalances as price moves. Mint the shortfall.
    function _pay(address token, address to, uint256 amt) internal {
        uint256 have = IERC20(token).balanceOf(address(this));
        if (have < amt) BoundedToken(token).mint(address(this), amt - have);
        IERC20(token).transfer(to, amt);
    }
}

/// @dev Either rejects every swap, which is what a floor the pool cannot meet looks like from the strategy, or
///      fills 1:1 from its own inventory. A rejection rolls back anything it wrote, so attempts are counted by
///      the strategy's `SwapFailed` event instead — the same signal an operator has.
contract BoundedRouter {
    bool public rejecting;
    uint256 public fills;

    function setRejecting(bool r) external {
        rejecting = r;
    }

    function swapExactInputSingleStrict(address tokenIn, address tokenOut, uint24, uint128 amountIn, uint256, uint256)
        external
        returns (uint256)
    {
        require(!rejecting, "Too little received");
        fills++;
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(msg.sender, amountIn);
        return amountIn;
    }
}

/// @dev The economics of `keeperCheck`, not its arithmetic. The live Bv3 and Sv3 vaults sat in range with a large
///      idle ASSET leg and no WETH, against a swap the pool could not fill. This pins what a keeper is allowed to
///      do with that inventory: never revert, do one bounded rotation, and then decline until something changes.
contract KeeperBoundedWorkBv3Test is Test {
    address internal constant WETH = V3Deployments8453.WETH;
    address internal constant NPM = V3Deployments8453.NPM;
    address internal constant FACTORY = V3Deployments8453.FACTORY;
    address internal constant KEEPER = address(0x1104);

    AutoStrategyBv3 internal s;
    BoundedPool internal pool;
    BoundedNpm internal npm;
    BoundedRouter internal router;
    BoundedToken internal asset;
    BoundedToken internal weth;

    function setUp() public {
        vm.etch(FACTORY, type(BoundedFactory).runtimeCode);
        vm.etch(WETH, type(BoundedToken).runtimeCode);
        vm.etch(NPM, type(BoundedNpm).runtimeCode);
        weth = BoundedToken(WETH);
        npm = BoundedNpm(NPM);

        pool = new BoundedPool();
        // Pinned above WETH's 0x4200…0006 so WETH is token0, as on the live Base pools.
        asset = BoundedToken(address(0x5555555555555555555555555555555555555555));
        vm.etch(address(asset), type(BoundedToken).runtimeCode);
        require(WETH < address(asset));
        pool.init(WETH, address(asset));
        pool.setTick(0);
        pool.setMeanTick(0);
        BoundedFactory(FACTORY).setPool(address(pool));
        npm.setPool(pool);

        router = new BoundedRouter();
        asset.mint(address(router), 1_000_000 ether);
        weth.mint(address(router), 1_000_000 ether);

        s = new AutoStrategyBv3(address(this));
        s.bootstrap(
            address(this),
            address(0x1101), // vault
            address(router),
            address(0x1103), // operatorRegistry
            KEEPER,
            address(0x1105), // feeManager
            address(0x1106), // shareStaking
            address(asset),
            10_000
        );
        vm.warp(1_000_000);
    }

    function _keeper() internal returns (bool) {
        vm.prank(KEEPER);
        return s.keeperCheck();
    }

    bytes32 internal constant SWAP_FAILED = keccak256("SwapFailed(address,uint256)");

    /// @dev Runs a pass and reports whether the strategy tried a swap that the router refused.
    function _keeperCountingRejections(uint256 expectedRejections, string memory why) internal returns (bool ok) {
        vm.recordLogs();
        ok = _keeper();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 rejections;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SWAP_FAILED) rejections++;
        }
        assertEq(rejections, expectedRejections, why);
    }

    /// @dev Balanced idle, no swap needed: the strategy opens its own position through the no-position branch.
    function _openPosition() internal {
        asset.mint(address(s), 10 ether);
        weth.mint(address(s), 10 ether);
        assertTrue(_keeper(), "seed mint");
        assertEq(npm.mints(), 1);
        assertTrue(s.hasBandBase());
    }

    function _pastCooldown() internal {
        vm.warp(block.timestamp + 2 hours + 1);
    }

    /// @dev Exactly the live inventory: a large ASSET leg and a wei of WETH, in range, with the seed mint's
    ///      cooldown already spent so the pass under test is the first one allowed to act.
    function _strandAsset() internal {
        asset.mint(address(s), 1_000 ether);
        weth.mint(address(s), 1);
        router.setRejecting(true);
        _pastCooldown();
    }

    function test_InRangeStrandedLegDoesOneRotationThenDeclines() public {
        _openPosition();
        _strandAsset();

        // Pass 1. The add cannot use one-sided inventory, so the strategy rotates: burn, try the swap, remint
        // at whatever ratio it has. That is the one piece of paid work this inventory is allowed.
        assertTrue(_keeperCountingRejections(1, "the swap was tried once"), "first pass rotates");
        assertEq(npm.decreases(), 1);
        assertEq(npm.mints(), 2);

        // Pass 2, same inventory, inside the cooldown. Nothing happens and the keeper is told so.
        assertFalse(_keeperCountingRejections(0, "no swap inside cooldown"), "inside cooldown");
        assertEq(npm.decreases(), 1);
        assertEq(npm.mints(), 2);

        // Passes 3..12 across ten cooldown windows. The latch remembers that this idle was already offered to
        // a rotation and refused, so no window reopens the churn.
        for (uint256 i = 0; i < 10; i++) {
            _pastCooldown();
            assertFalse(_keeperCountingRejections(0, "no swap while latched"), "latched");
        }
        assertEq(npm.decreases(), 1, "no further burns");
        assertEq(npm.mints(), 2, "no further mints");
    }

    /// @dev A deposit that lands the missing leg is what should reopen the path — and it is the add that
    ///      absorbs it, not another rotation.
    function test_NewInventoryIsAbsorbedByTheAddNotAnotherRotation() public {
        _openPosition();
        _strandAsset();
        assertTrue(_keeper());
        _pastCooldown();
        assertFalse(_keeper(), "latched before the deposit");
        uint256 increasesBefore = npm.increases();

        weth.mint(address(s), 100 ether);
        _pastCooldown();
        assertTrue(_keeper(), "new inventory deployed");
        assertEq(npm.increases(), increasesBefore + 1, "through the add");
        assertEq(npm.mints(), 2, "not through a remint");
        assertEq(npm.decreases(), 1);
    }

    /// @dev Out of range with a rejected swap the remint has nothing two-sided to open with. It must decline,
    ///      not revert: the keeper's simulation sees `false` and sends nothing.
    function test_OutOfRangeOneSidedRemintDeclinesWithoutReverting() public {
        _openPosition();
        router.setRejecting(true);
        // Price leaves the band. The exit pays out one token; the swap that would rebalance it is refused.
        pool.setTick(1_400);
        pool.setMeanTick(1_400);

        assertFalse(_keeper(), "declined");
        assertEq(npm.decreases(), 1, "the old range was exited");
        assertEq(npm.mints(), 1, "nothing minted one-sided");
        assertGt(s.balanceOfIdle(), 0, "inventory sits idle, intact");
    }

    /// @dev When the swap does fill, the same inventory goes to work and stops being material. Keeps the bound
    ///      from being a refusal to ever deploy.
    function test_FillableSwapDeploysTheStrandedLeg() public {
        _openPosition();
        asset.mint(address(s), 1_000 ether);
        _pastCooldown();

        assertTrue(_keeper(), "rotated with a fill");
        assertEq(router.fills(), 1);
        // The idle that was 1_000 ASSET is now inside the position; what remains is below the 5% bar.
        _pastCooldown();
        assertFalse(_keeper(), "nothing material left");
    }

    /// @dev Whatever the keeper does, it must never revert on the way. A revert is the one outcome that
    ///      costs gas forever, because it erases the cooldown and the latch that would have stopped it.
    function testFuzz_KeeperNeverReverts(uint96 idleAsset, uint96 idleWeth, int24 tickMove, bool reject) public {
        _openPosition();
        tickMove = int24(bound(tickMove, -2_000, 2_000));
        pool.setTick(tickMove);
        pool.setMeanTick(tickMove);
        asset.mint(address(s), idleAsset);
        weth.mint(address(s), idleWeth);
        router.setRejecting(reject);

        for (uint256 i = 0; i < 4; i++) {
            _keeper();
            _pastCooldown();
        }
    }
}
