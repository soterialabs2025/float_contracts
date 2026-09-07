// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {V4Deployments8453} from "../contracts/v4/V4Deployments8453.sol";
import {TickMath} from "../contracts/v4/libraries/TickMath.sol";
import {AutoStrategyBv4} from "../contracts/auto-vault-base-v4/AutoStrategyBv4.sol";
import {LiquidityLibraryV4} from "../contracts/auto-vault-base-v4/libraries/LiquidityLibraryV4.sol";
import {IAutoSwapRouterBv4} from "../contracts/auto-vault-base-v4/interfaces/IAutoSwapRouterBv4.sol";
import {
    HarvestToken,
    HarvestPermit2,
    HarvestRegistry,
    HarvestStaking,
    HarvestPoolManager,
    MockPosm
} from "./HarvestNoSwapBv4.t.sol";

/// @dev Settles one-for-one, the true rate at tick 0. The sibling file's router pays only the caller's slippage
///      floor, and that shortfall would land inside the value totals asserted here and be read as a peel.
contract FairSwapRouter {
    function swapExactInputSingleStrict(
        bool zeroForOne,
        uint128 amountIn,
        uint128,
        uint256,
        IAutoSwapRouterBv4.AutoPoolKey calldata key,
        bytes calldata
    ) external returns (uint256) {
        address tokenIn = zeroForOne ? key.currency0 : key.currency1;
        address tokenOut = zeroForOne ? key.currency1 : key.currency0;
        HarvestToken(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        HarvestToken(tokenOut).mint(msg.sender, amountIn);
        return amountIn;
    }
}

/// @notice Cover for realising fees before a deposit is priced, and for sizing the reserve peel to that deposit.
/// @dev Two changes are pinned here. The vault now calls `syncFees` before it samples NAV, because fees the pool
///      still owes are invisible to `poolValue()` and a depositor priced against that NAV is handed shares in fees
///      they did not earn. And the peel is now sized to the arriving capital rather than to the whole deployable
///      balance, because fees `syncFees` just realised were already peeled by `_collectAllFees` and peeling the
///      balance would reserve them a second time.
/// @dev This test contract is the vault: `bootstrap` is given `address(this)`, so it can drive `syncFees` and
///      `deposit` in the same order `AutoVaultBv4._mintSharesAndDeploy` does.
contract DepositFeeSyncBv4Test is Test {
    address internal constant PM_ADDR = V4Deployments8453.POOL_MANAGER;
    address internal constant POSM_ADDR = V4Deployments8453.POSITION_MANAGER;
    address internal constant PERMIT2_ADDR = V4Deployments8453.PERMIT2;
    address internal constant WETH_ADDR = V4Deployments8453.WETH;

    address internal constant KEEPER = address(0xC0FFEE);
    address internal constant REGISTRY = address(0xDECAF);
    address internal constant STAKING = address(0xA6);
    address internal constant FEE_MANAGER = address(0xA5);

    uint256 internal constant ONE = 1e18;
    uint256 internal constant DEPOSIT = 1e18;
    uint256 internal constant FEES = 4e17;

    uint256 internal constant DIVISOR = 10_000;
    uint256 internal constant PROTOCOL_FEE_BPS = 600;
    uint256 internal constant RESERVE_BPS = 5_000;

    /// @dev Fees left after the protocol skim, which is what the reserve rules actually apply to.
    uint256 internal constant NET_FEES = FEES * (DIVISOR - PROTOCOL_FEE_BPS) / DIVISOR;

    /// @dev Rounding room for `mulDiv` and the tick-0 price conversion. Four orders of magnitude below the
    ///      smallest gap any assertion here has to resolve.
    uint256 internal constant TOL = 1e14;

    uint256 internal constant FIRST_POSITION = 1;

    HarvestPoolManager internal pm;
    MockPosm internal posm;
    FairSwapRouter internal router;
    HarvestToken internal asset;
    AutoStrategyBv4 internal s;

    uint256 internal clock;
    uint256 internal blockNo;

    function setUp() public {
        vm.etch(PM_ADDR, type(HarvestPoolManager).runtimeCode);
        vm.etch(POSM_ADDR, type(MockPosm).runtimeCode);
        vm.etch(PERMIT2_ADDR, type(HarvestPermit2).runtimeCode);
        vm.etch(WETH_ADDR, type(HarvestToken).runtimeCode);
        vm.etch(REGISTRY, type(HarvestRegistry).runtimeCode);
        vm.etch(STAKING, type(HarvestStaking).runtimeCode);
        pm = HarvestPoolManager(PM_ADDR);
        posm = MockPosm(POSM_ADDR);
        router = new FairSwapRouter();

        asset = new HarvestToken();
        // Keep ASSET above WETH so currency0 is WETH and the fee legs below are the right way round.
        while (address(asset) < WETH_ADDR) {
            asset = new HarvestToken();
        }

        clock = 100_000_000;
        blockNo = 100;
        vm.warp(clock);
        vm.roll(blockNo);

        _setTick(0);

        s = new AutoStrategyBv4(address(this));
        LiquidityLibraryV4.PoolKey memory key = LiquidityLibraryV4.PoolKey({
            currency0: WETH_ADDR,
            currency1: address(asset),
            fee: 3_000,
            tickSpacing: 200,
            hooks: address(0)
        });
        // Owner and vault are both this contract: `syncFees` and `deposit` are vault-gated, and driving them in
        // the vault's own order is the whole point of the harness.
        s.bootstrap(
            address(this),
            address(this),
            address(router),
            REGISTRY,
            KEEPER,
            FEE_MANAGER,
            STAKING,
            address(asset),
            key,
            ""
        );
    }

    function _setTick(int24 tick) internal {
        pm.setSlot0(TickMath.getSqrtRatioAtTick(tick), tick);
    }

    /// @dev Time and blocks move together, tracked here rather than read back: under `via_ir` the optimizer
    ///      treats `block.timestamp` as constant within a call frame and reuses a stale read.
    function _advance(uint256 secs) internal {
        clock += secs;
        blockNo += secs / 2;
        vm.warp(clock);
        vm.roll(blockNo);
    }

    /// @dev At tick 0 the legs price 1:1, so equal amounts already sit at the 5,000 bps target and the mint has
    ///      nothing to swap.
    function _mintBalancedPosition() internal {
        HarvestToken(WETH_ADDR).mint(address(s), ONE);
        asset.mint(address(s), ONE);
        vm.prank(KEEPER);
        s.keeperCheck();
        assertGt(posm.getPositionLiquidity(FIRST_POSITION), 0, "position expected");
        // Leave the block the mint seeded the price reference in, or the swap gate returns a zero floor and
        // `_swap` skips, so a deposit measured here would balance without ever reaching the router.
        _advance(1 hours);
    }

    function _deposit(uint256 amount) internal {
        HarvestToken(WETH_ADDR).mint(address(this), amount);
        HarvestToken(WETH_ADDR).approve(address(s), amount);
        s.deposit(amount);
    }

    /// @dev Both buckets in one number. Tick 0 prices them 1:1, so they add directly.
    function _reservedValue() internal view returns (uint256) {
        return s.reservedAsset() + s.reservedWeth();
    }

    /// @dev The mock PositionManager records liquidity without taking tokens, so everything funded for the mint
    ///      is still sitting idle afterwards. That is the condition the peel used to mis-size against, and it is
    ///      why these tests can pose the question without contriving a balance.
    function _idleValue() internal view returns (uint256) {
        return HarvestToken(WETH_ADDR).balanceOf(address(s)) + asset.balanceOf(address(s));
    }

    // --- the peel is sized to the deposit, not to the balance ---

    function test_MintLeavesIdleBehindAndReservesNothing() public {
        _mintBalancedPosition();

        assertApproxEqAbs(_idleValue(), 2 * ONE, TOL, "premise: idle survives the mint");
        assertEq(_reservedValue(), 0, "premise: re-centring does not peel");
    }

    /// @dev The pre-existing half of the bug, reachable without any fees. Idle left over from an earlier
    ///      operation was peeled again by the next deposit that happened to find it.
    function test_DepositPeelsItsOwnHalfAndNotTheIdleAlreadyThere() public {
        _mintBalancedPosition();

        _deposit(DEPOSIT);

        assertApproxEqAbs(_reservedValue(), DEPOSIT / 2, TOL, "half of the deposit, and nothing more");
    }

    /// @dev Anti-vacuity for the above: states the number the old peel produced, so the assertion is pinning a
    ///      behaviour rather than agreeing with whatever the code happens to do.
    function test_TheOldPeelWouldHaveReservedFarMore() public {
        _mintBalancedPosition();
        uint256 deployableBefore = _idleValue();

        _deposit(DEPOSIT);

        uint256 flatPeel = (deployableBefore + DEPOSIT) / 2;
        assertApproxEqAbs(flatPeel, 15e17, TOL, "the balance-wide peel this replaced");
        assertLt(_reservedValue(), flatPeel, "sized to the deposit, not to the balance");
    }

    // --- fees are peeled once, by the collect ---

    function test_SyncFeesReservesHalfTheNetFees() public {
        _mintBalancedPosition();
        posm.setPendingFees(0, FEES);

        s.syncFees();

        assertApproxEqAbs(_reservedValue(), NET_FEES / 2, TOL, "reserveBps of the post-skim fees");
    }

    /// @dev The change proper. Collecting into idle and then peeling the balance would reserve the fees twice and
    ///      land them at 75%. They are peeled once, by `_collectAllFees`, and the deposit peels only itself.
    function test_FeesRealisedBeforeADepositArePeeledOnceNotTwice() public {
        _mintBalancedPosition();
        posm.setPendingFees(0, FEES);

        s.syncFees();
        _deposit(DEPOSIT);

        assertApproxEqAbs(_reservedValue(), NET_FEES / 2 + DEPOSIT / 2, TOL, "half the fees, half the deposit");

        // The floor a second peel could not have stayed under even if nothing else had been idle: fees at 75%
        // plus half the deposit. The peel this replaced overshot it by more, because the idle from the mint was
        // in the base as well, but this is the bound that holds regardless of what else is sitting there.
        uint256 doublePeeled = NET_FEES * 3 / 4 + DEPOSIT / 2;
        assertLt(_reservedValue(), doublePeeled - TOL, "fees must not be reserved at 75%");
    }

    /// @dev Both buckets have to end up funded or `_fundDeficitFromReserve` has only one side to draw on and
    ///      falls through to a swap, which is the cost the reserve exists to avoid.
    function test_PeelFundsBothReserveBuckets() public {
        _mintBalancedPosition();
        posm.setPendingFees(0, FEES);

        s.syncFees();
        _deposit(DEPOSIT);

        assertGt(s.reservedAsset(), 0, "asset bucket");
        assertGt(s.reservedWeth(), 0, "weth bucket");
    }

    // --- the pricing half: NAV carries the fees before the deposit is priced ---

    /// @dev What the vault gains by calling `syncFees` first. Uncollected fees are absent from `poolValue()`, so
    ///      a NAV sampled before the collect understates what existing holders own, and the depositor priced
    ///      against it receives shares in the difference.
    function test_SyncFeesLiftsNavBeforeTheDepositIsPriced() public {
        _mintBalancedPosition();
        posm.setPendingFees(0, FEES);

        uint256 navStale = s.poolValue();
        s.syncFees();
        uint256 navRealised = s.poolValue();

        assertApproxEqAbs(navRealised - navStale, NET_FEES, TOL, "fees are on the books before pricing");
    }

    /// @dev Anti-vacuity: `syncFees` has to do the routing too, not merely move tokens into idle. If the skim and
    ///      the accounting were skipped the reserve numbers above would still hold and say nothing.
    function test_SyncFeesRoutesTheProtocolSkimAndRecordsTheFees() public {
        _mintBalancedPosition();
        posm.setPendingFees(0, FEES);

        s.syncFees();

        uint256 skimmed = asset.balanceOf(FEE_MANAGER) + asset.balanceOf(STAKING);
        assertApproxEqAbs(skimmed, FEES * PROTOCOL_FEE_BPS / DIVISOR, TOL, "protocol skim was routed");
        assertApproxEqAbs(s.UniswapFeesCollected(), NET_FEES, TOL, "fees were recorded");
    }

    /// @dev A deposit with nothing pending must not be charged for the sync.
    function test_SyncFeesWithoutPendingFeesIsANoOp() public {
        _mintBalancedPosition();

        s.syncFees();

        assertEq(_reservedValue(), 0);
        assertEq(s.UniswapFeesCollected(), 0);
    }

    /// @dev Only the vault drives this. It moves value between buckets and routes a skim, so an open door would
    ///      let anyone force both at a tick of their choosing.
    function test_SyncFeesIsVaultOnly() public {
        _mintBalancedPosition();

        vm.prank(KEEPER);
        vm.expectRevert();
        s.syncFees();
    }
}
