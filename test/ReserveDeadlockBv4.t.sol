// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {V4Deployments8453} from "../contracts/v4/V4Deployments8453.sol";
import {TickMath} from "../contracts/v4/libraries/TickMath.sol";
import {AutoStrategyBv4} from "../contracts/auto-vault-base-v4/AutoStrategyBv4.sol";
import {LiquidityLibraryV4} from "../contracts/auto-vault-base-v4/libraries/LiquidityLibraryV4.sol";
import {
    HarvestToken,
    HarvestPermit2,
    HarvestRegistry,
    HarvestStaking,
    HarvestPoolManager,
    CountingSwapRouter
} from "./HarvestNoSwapBv4.t.sol";

/// @notice Position manager fixture that swallows the whole currency1 balance when liquidity is added.
/// @dev Not a pool model, and no assertion here depends on the amounts. Its only job is to reach the state the
///      live Bv4 strategy was actually in: an in-range position whose matching leg has been consumed, leaving
///      idle that is material by value but one-sided, which is the input that prices to zero liquidity. The
///      stock harness mock moves no tokens, so under it deployable is never one-sided and this bug cannot occur.
contract ConsumingPosm {
    uint8 internal constant INCREASE = 0x00;
    uint8 internal constant DECREASE = 0x01;
    uint8 internal constant MINT = 0x02;

    uint256 internal _next;
    mapping(uint256 => uint128) internal _liq;
    address public currency1;

    function setCurrency1(address c1) external {
        currency1 = c1;
    }

    function nextTokenId() public view returns (uint256) {
        return _next == 0 ? 1 : _next;
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128) {
        return _liq[tokenId];
    }

    function _drainCurrency1(address from) internal {
        uint256 bal = HarvestToken(currency1).balanceOf(from);
        if (bal > 0) HarvestToken(currency1).transferFrom(from, address(this), bal);
    }

    function modifyLiquidities(bytes calldata unlockData, uint256) external payable {
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        uint8 action = uint8(actions[0]);

        if (action == MINT) {
            (,,, uint128 liq,,,,) = abi.decode(
                params[0],
                (LiquidityLibraryV4.PoolKey, int24, int24, uint128, uint128, uint128, address, bytes)
            );
            uint256 id = nextTokenId();
            _liq[id] = liq;
            _next = id + 1;
            _drainCurrency1(msg.sender);
        } else if (action == INCREASE) {
            (uint256 id, uint128 liq,,,) = abi.decode(params[0], (uint256, uint128, uint128, uint128, bytes));
            _liq[id] += liq;
            _drainCurrency1(msg.sender);
        } else if (action == DECREASE) {
            (uint256 id, uint256 liq,,,) = abi.decode(params[0], (uint256, uint256, uint128, uint128, bytes));
            if (liq > 0) _liq[id] = liq >= _liq[id] ? 0 : _liq[id] - uint128(liq);
        }
    }
}

/// @notice Regression cover for the in-range zero-liquidity deadlock observed on Bv4 strategy
///         `0x3345799B0ACa9895e481445701828671F7553933`.
/// @dev Live symptom: `performUpkeepBatch` succeeded every keeper pass, burned ~199k gas, emitted no logs and
///      deployed nothing, because the add priced to zero liquidity against a one-sided deployable book while the
///      `minHarvestDelay` cooldown suppressed the remint that would have fixed it — and `keeperCheck` still
///      returned true, so the keeper recorded the pass as successful work.
contract ReserveDeadlockBv4Test is Test {
    address internal constant PM_ADDR = V4Deployments8453.POOL_MANAGER;
    address internal constant POSM_ADDR = V4Deployments8453.POSITION_MANAGER;
    address internal constant PERMIT2_ADDR = V4Deployments8453.PERMIT2;
    address internal constant WETH_ADDR = V4Deployments8453.WETH;

    address internal constant KEEPER = address(0xC0FFEE);
    address internal constant REGISTRY = address(0xDECAF);
    address internal constant STAKING = address(0xA6);
    address internal constant FEE_MANAGER = address(0xA5);

    uint256 internal constant ONE = 1e18;
    uint256 internal constant FIRST_POSITION = 1;
    uint256 internal constant SECOND_POSITION = 2;

    HarvestPoolManager internal pm;
    ConsumingPosm internal posm;
    CountingSwapRouter internal router;
    HarvestToken internal asset;
    AutoStrategyBv4 internal s;

    uint256 internal clock;
    uint256 internal blockNo;

    function setUp() public {
        vm.etch(PM_ADDR, type(HarvestPoolManager).runtimeCode);
        vm.etch(POSM_ADDR, type(ConsumingPosm).runtimeCode);
        vm.etch(PERMIT2_ADDR, type(HarvestPermit2).runtimeCode);
        vm.etch(WETH_ADDR, type(HarvestToken).runtimeCode);
        vm.etch(REGISTRY, type(HarvestRegistry).runtimeCode);
        vm.etch(STAKING, type(HarvestStaking).runtimeCode);
        pm = HarvestPoolManager(PM_ADDR);
        posm = ConsumingPosm(POSM_ADDR);
        router = new CountingSwapRouter();

        asset = new HarvestToken();
        // Keep ASSET above WETH so currency0 is WETH and the asset is the currency1 leg.
        while (address(asset) < WETH_ADDR) {
            asset = new HarvestToken();
        }
        posm.setCurrency1(address(asset));

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
        s.bootstrap(
            address(this), address(0xA1), address(router), REGISTRY, KEEPER, FEE_MANAGER, STAKING,
            address(asset), key, ""
        );
    }

    function _setTick(int24 tick) internal {
        pm.setSlot0(TickMath.getSqrtRatioAtTick(tick), tick);
    }

    function _advance(uint256 secs) internal {
        clock += secs;
        blockNo += secs / 2;
        vm.warp(clock);
        vm.roll(blockNo);
    }

    /// @dev Leaves an in-range position plus WETH-only idle: the asset leg went into the mint.
    function _oneSidedInRangePosition() internal {
        HarvestToken(WETH_ADDR).mint(address(s), ONE);
        asset.mint(address(s), ONE);

        vm.prank(KEEPER);
        s.keeperCheck();
        assertGt(posm.getPositionLiquidity(FIRST_POSITION), 0, "position expected");

        // Top the WETH leg back up so idle is material by value but has no asset to pair with.
        HarvestToken(WETH_ADDR).mint(address(s), ONE);
        // Out of the reference block so the swap gate is open on the next pass.
        _advance(1 hours);

        assertEq(asset.balanceOf(address(s)), 0, "asset leg consumed by the mint");
        assertGt(HarvestToken(WETH_ADDR).balanceOf(address(s)), 0, "WETH idle is material");
    }

    /// @dev The bug itself: in range, cooldown live, and an add that can only price to zero. Before the fix this
    ///      returned true having moved nothing, so the keeper re-ran it forever at ~199k gas a pass.
    function test_ZeroLiquidityAddDoesNotReportSuccess() public {
        _oneSidedInRangePosition();
        uint128 before = posm.getPositionLiquidity(FIRST_POSITION);

        vm.prank(KEEPER);
        bool acted = s.keeperCheck();

        bool movedSomething =
            posm.getPositionLiquidity(FIRST_POSITION) != before || posm.getPositionLiquidity(SECOND_POSITION) > 0;
        assertTrue(movedSomething || !acted, "keeperCheck must not claim work it did not do");
    }

    /// @dev And it must actually deploy: the cooldown cannot strand inventory the live band can never absorb.
    function test_OneSidedIdleIsDeployedNotStranded() public {
        _oneSidedInRangePosition();

        vm.prank(KEEPER);
        bool acted = s.keeperCheck();

        assertTrue(acted, "the pass did real work");
        assertGt(posm.getPositionLiquidity(SECOND_POSITION), 0, "idle was redeployed through a remint");
    }

    /// @dev Anti-vacuity: an unfunded strategy has genuinely nothing to do, and says so.
    function test_NothingToDoReturnsFalse() public {
        vm.prank(KEEPER);
        bool acted = s.keeperCheck();

        assertFalse(acted, "no position and no inventory, so no work");
        assertEq(posm.getPositionLiquidity(FIRST_POSITION), 0, "nothing was minted");
    }
}
