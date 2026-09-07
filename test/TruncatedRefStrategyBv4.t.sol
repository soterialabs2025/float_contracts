// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {V4Deployments8453} from "../contracts/v4/V4Deployments8453.sol";
import {TickMath} from "../contracts/v4/libraries/TickMath.sol";
import {AutoStrategyBv4} from "../contracts/auto-vault-base-v4/AutoStrategyBv4.sol";
import {LiquidityLibraryV4} from "../contracts/auto-vault-base-v4/libraries/LiquidityLibraryV4.sol";
import {SwapGateLib} from "../contracts/auto-vault-base-v4/libraries/SwapGateLib.sol";

contract RefToken is ERC20 {
    constructor() ERC20("M", "M") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev `_giveAllowances` calls into Permit2 during bootstrap; nothing here needs to model it.
contract RefMockPermit2 {
    function approve(address, address, uint160, uint48) external {}
}

/// @dev Denies everyone. Without code at the registry address the unauthorised path would revert on decoding an
///      EOA return rather than on the strategy's own check, which would pass for the wrong reason.
contract DenyRegistry {
    function isOperator(address) external pure returns (bool) {
        return false;
    }
}

/// @dev Stands in for the v4 PoolManager. `extsload` ignores the slot key and returns a packed slot0, so
///      `StateLibrary.getSlot0` resolves all four fields without modelling real pool storage.
contract RefMockPoolManager {
    bytes32 internal _slot0;

    /// @dev Layout per StateLibrary: lpFee | protocolFee | tick | sqrtPriceX96.
    function setSlot0(uint160 sqrtPriceX96, int24 tick) external {
        _slot0 = bytes32(uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160) | (uint256(uint24(3_000)) << 208));
    }

    function extsload(bytes32) external view returns (bytes32) {
        return _slot0;
    }
}

/// @notice Strategy-level cover for the truncated price reference: the keeper cadence that writes it and the NAV
///         the vault mints against reading off it.
/// @dev `TruncatedRefBv4` pins the pure arithmetic in `SwapGateLib`. This drives the same mechanism through
///      `AutoStrategyBv4` itself, where the reference is real storage written under a rate limit and read against
///      a live slot0, so it catches wiring faults the library tests cannot see: a refresh that forgets to clamp,
///      a rate limit that lets a caller re-write within the window, or a NAV that quietly falls back to spot.
contract TruncatedRefStrategyBv4Test is Test {
    address internal constant PM_ADDR = V4Deployments8453.POOL_MANAGER;
    address internal constant PERMIT2_ADDR = V4Deployments8453.PERMIT2;
    address internal constant WETH_ADDR = V4Deployments8453.WETH;

    address internal constant KEEPER = address(0xC0FFEE);
    address internal constant REGISTRY = address(0xDECAF);
    address internal constant STRANGER = address(0xBADD);

    /// @dev Manager defaults: half a tick per second, capped at 2,000 ticks, one write per five minutes.
    uint256 internal constant SEC_PER_TICK = 2;
    uint256 internal constant MAX_DRIFT = 2_000;
    uint256 internal constant MIN_INTERVAL = 5 minutes;

    /// @dev ~1.50x. Comfortably past the 2,000 tick cap, so the reference can never fully adopt it.
    int24 internal constant SPIKE_TICK = 4_055;

    uint256 internal constant ONE = 1e18;

    RefMockPoolManager internal pm;
    RefToken internal asset;
    AutoStrategyBv4 internal s;

    /// @dev Time is tracked here rather than read back off `block.timestamp` between warps. Under `via_ir` the
    ///      optimizer treats `TIMESTAMP` as constant within a call frame and reuses a stale read, so a second
    ///      `vm.warp(block.timestamp + delta)` in one test silently warps to the same instant as the first.
    uint256 internal clock;

    function _advance(uint256 secs) internal {
        clock += secs;
        vm.warp(clock);
    }

    function setUp() public {
        vm.etch(PM_ADDR, type(RefMockPoolManager).runtimeCode);
        vm.etch(PERMIT2_ADDR, type(RefMockPermit2).runtimeCode);
        vm.etch(WETH_ADDR, type(RefToken).runtimeCode);
        vm.etch(REGISTRY, type(DenyRegistry).runtimeCode);
        pm = RefMockPoolManager(PM_ADDR);

        asset = new RefToken();
        // Keep ASSET above WETH so currency0 is WETH, matching the pricing direction asserted below.
        while (address(asset) < WETH_ADDR) {
            asset = new RefToken();
        }

        // Far enough in that a 30-day-old reference is still a valid timestamp.
        clock = 100_000_000;
        vm.warp(clock);
        vm.roll(100);

        s = _strategy();
    }

    /// @dev `bootstrap` is `onlyFactory`, so this contract is the factory, and also the owner.
    function _strategy() internal returns (AutoStrategyBv4 st) {
        st = new AutoStrategyBv4(address(this));
        LiquidityLibraryV4.PoolKey memory key = LiquidityLibraryV4.PoolKey({
            currency0: WETH_ADDR,
            currency1: address(asset),
            fee: 3_000,
            tickSpacing: 60,
            hooks: address(0)
        });
        st.bootstrap(
            address(this), address(0xA1), address(0xA2), REGISTRY, KEEPER, address(0xA5), address(0xA6),
            address(asset), key, ""
        );
    }

    function _setTick(int24 tick) internal {
        pm.setSlot0(TickMath.getSqrtRatioAtTick(tick), tick);
    }

    function _refresh() internal returns (bool) {
        vm.prank(KEEPER);
        return s.refreshPriceRef();
    }

    /// @dev One WETH and one ASSET sitting idle. With no position `poolValueRef` is exactly these two legs, so
    ///      every NAV assertion below is a direct statement about the price it valued them at.
    function _fundOneEach() internal {
        RefToken(WETH_ADDR).mint(address(s), ONE);
        asset.mint(address(s), ONE);
    }

    /// @dev What those two legs are worth valued at `tick`. Passing `SPIKE_TICK` gives the raw-spot number the
    ///      reference exists to avoid handing the vault.
    function _navAtTick(int24 tick) internal pure returns (uint256) {
        return ONE + (ONE * ONE) / SwapGateLib.priceAtTick(tick, true);
    }

    // --- who may write the reference ---

    function test_StrangerCannotRefresh() public {
        _setTick(0);
        vm.prank(STRANGER);
        vm.expectRevert(AutoStrategyBv4.E.selector);
        s.refreshPriceRef();
    }

    function test_KeeperAndOwnerMayRefresh() public {
        _setTick(0);
        assertTrue(_refresh(), "keeper");

        _advance(MIN_INTERVAL);
        // This contract is the owner, so the registry never gets consulted.
        assertTrue(s.refreshPriceRef(), "owner");
    }

    // --- seeding ---

    /// @dev The first write has nothing to clamp against, so it takes spot whole. That is the only write that
    ///      can, which is why `_mintPosition` seeds it rather than leaving it to a keeper that may be front-run.
    function test_FirstWriteAdoptsSpotAndStampsTimeAndBlock() public {
        _setTick(SPIKE_TICK);
        assertTrue(_refresh());

        assertEq(s.refTick(), SPIKE_TICK, "unseeded reference takes spot");
        assertEq(s.refTime(), uint64(block.timestamp));
        assertEq(s.refBlock(), uint64(block.number), "the swap gate refuses a reference set this block");
    }

    function test_UninitialisedPoolWritesNothing() public {
        pm.setSlot0(0, 0);
        assertFalse(_refresh(), "no price to record");
        assertEq(s.refTime(), 0, "must stay unseeded rather than record tick zero");
        assertEq(s.poolValueRef(), 0);
    }

    // --- the rate limit ---

    function test_SecondWriteInTheSameBlockIsRefused() public {
        _setTick(0);
        assertTrue(_refresh());
        uint64 seededAt = s.refTime();

        _setTick(SPIKE_TICK);
        assertFalse(_refresh(), "inside the window");
        assertEq(s.refTick(), 0, "and wrote nothing");
        assertEq(s.refTime(), seededAt);
    }

    /// @dev The boundary, because an off-by-one here is the difference between one write per window and two.
    function test_WindowOpensExactlyAtTheInterval() public {
        _setTick(0);
        _refresh();

        _advance(MIN_INTERVAL - 1);
        assertFalse(_refresh(), "one second early");

        _advance(1);
        assertTrue(_refresh(), "on the interval");
    }

    function test_OwnerCanWidenTheWindow() public {
        _setTick(0);
        _refresh();
        s.setMinRefUpdateInterval(1 hours);

        _advance(MIN_INTERVAL);
        assertFalse(_refresh(), "the old window no longer opens it");

        _advance(1 hours);
        assertTrue(_refresh());
    }

    // --- what a write may move ---

    /// @dev The security claim at strategy level. An attacker who owns the pool for one window and catches the
    ///      keeper write still only moves the reference by the drift that window earned.
    function test_AWriteMovesOnlyTheDriftEarnedSinceTheLast() public {
        _setTick(0);
        _refresh();

        _setTick(SPIKE_TICK);
        _advance(MIN_INTERVAL);
        assertTrue(_refresh());
        assertEq(s.refTick(), 150, "five minutes at half a tick per second");

        _advance(MIN_INTERVAL);
        assertTrue(_refresh());
        assertEq(s.refTick(), 300, "and again, no faster");
    }

    /// @dev A genuine move is not resisted forever. Sustained pressure is tracked; it just costs real time.
    function test_ReferenceConvergesOnASustainedMove() public {
        _setTick(0);
        _refresh();
        _setTick(600);

        for (uint256 i = 0; i < 4; i++) {
            _advance(MIN_INTERVAL);
            _refresh();
        }
        assertEq(s.refTick(), 600, "four windows buy 600 ticks, so it arrives exactly");
    }

    // --- the NAV the vault mints against ---

    function test_NavIsZeroUntilSeeded() public {
        _setTick(0);
        _fundOneEach();
        assertEq(s.poolValueRef(), 0, "no reference, no reference NAV");
    }

    function test_NavPricesIdleLegsAtTheReference() public {
        _setTick(0);
        _refresh();
        _fundOneEach();
        assertEq(s.poolValueRef(), 2 * ONE, "one WETH plus one ASSET at parity");
    }

    /// @dev The whole point of the mechanism. A spot spike in the deposit's own block does not reach the NAV, so
    ///      it cannot be used to mint shares cheaply or to make an honest depositor's shares dear.
    function test_SpotSpikeInTheSameBlockDoesNotReachNav() public {
        _setTick(0);
        _refresh();
        _fundOneEach();

        _setTick(SPIKE_TICK);
        assertEq(s.poolValueRef(), 2 * ONE, "unmoved");
        assertGt(s.poolValueRef(), _navAtTick(SPIKE_TICK), "and well above what spot would have said");
    }

    /// @dev Degradation, not refusal: a reference nobody has refreshed relaxes toward spot instead of halting
    ///      deposits. The vault takes `min(spot, ref)`, so relaxing is safe; halting would not be.
    function test_NavRelaxesTowardSpotAsTheReferenceAges() public {
        _setTick(0);
        _refresh();
        _fundOneEach();
        _setTick(SPIKE_TICK);

        _advance(30 minutes);
        uint256 relaxed = s.poolValueRef();

        assertEq(relaxed, _navAtTick(900), "30 minutes earns 900 ticks");
        assertLt(relaxed, 2 * ONE, "moved toward spot");
        assertGt(relaxed, _navAtTick(SPIKE_TICK), "but not all the way");
    }

    /// @dev And the cap is what stops the relaxation completing. Past the ceiling a neglected reference stays
    ///      put rather than becoming a spot feed wearing a reference's name.
    function test_DriftCapStopsNavEverReachingSpot() public {
        _setTick(0);
        _refresh();
        _fundOneEach();
        _setTick(SPIKE_TICK);

        _advance(30 days);
        uint256 capped = s.poolValueRef();

        assertEq(capped, _navAtTick(int24(uint24(MAX_DRIFT))), "pinned at the 2,000 tick ceiling");
        assertGt(capped, _navAtTick(SPIKE_TICK), "never converges, because the move outran the cap");
    }

    /// @dev Refreshing is what actually lets the NAV track a real move, and it is rate-limited, so the vault's
    ///      view of price can only ever walk.
    function test_RefreshingIsWhatMovesTheNav() public {
        _setTick(0);
        _refresh();
        _fundOneEach();
        _setTick(SPIKE_TICK);

        uint256 before = s.poolValueRef();
        _advance(MIN_INTERVAL);
        _refresh();
        uint256 after_ = s.poolValueRef();

        assertLt(after_, before, "the write moved it");
        assertEq(after_, _navAtTick(150), "by exactly one window's drift");
    }
}
