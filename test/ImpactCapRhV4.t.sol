// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LiquidityLibraryV4} from "../contracts/auto-vault-rh-v4/libraries/LiquidityLibraryV4.sol";
import {SwapGateLib} from "../contracts/auto-vault-rh-v4/libraries/SwapGateLib.sol";
import {IPoolManagerV4} from "../contracts/auto-vault-rh-v4/interfaces/IPoolManagerV4.sol";
import {PoolKey as CorePoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "../lib/v4-core/src/types/Currency.sol";
import {IHooks} from "../lib/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "../lib/v4-core/src/types/PoolId.sol";

/// @dev Stands in for the v4 PoolManager, keyed properly rather than returning one value for every slot. slot0 and
///      liquidity live three slots apart in `Pool.State`, so a mock that ignores the key would hand the same word to
///      both reads and quietly report a liquidity equal to the packed price.
contract ImpactMockPoolManager {
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint256 internal constant LIQUIDITY_OFFSET = 3;

    mapping(bytes32 => bytes32) internal _slots;

    function setPool(bytes32 poolId, uint160 sqrtPriceX96, int24 tick, uint128 liquidity) external {
        bytes32 base = keccak256(abi.encodePacked(poolId, POOLS_SLOT));
        _slots[base] = bytes32(uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160));
        _slots[bytes32(uint256(base) + LIQUIDITY_OFFSET)] = bytes32(uint256(liquidity));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }
}

/// @dev Cover for the term a swap output floor cannot supply. `minOut` prices a trade at the anchor and deducts the
///      pool fee and a flat tolerance, so it never sees trade size: a rebalance large against the pool's own depth
///      walks the curve past its own floor and reverts on every keeper pass. `swapInputCap` bounds the input
///      instead, which is what lets the floor stay tight.
contract ImpactCapRhV4Test is Test {
    /// @dev sqrt(1) in Q96, i.e. currency0 and currency1 at parity.
    uint160 internal constant SQRT_ONE = 79228162514264337593543950336;
    uint256 internal constant DIVISOR = 10_000;

    ImpactMockPoolManager internal pm;

    function setUp() public {
        pm = new ImpactMockPoolManager();
        vm.roll(100);
        vm.warp(1_000_000);
    }

    function _key() internal pure returns (LiquidityLibraryV4.PoolKey memory) {
        return LiquidityLibraryV4.PoolKey({
            currency0: address(0),
            currency1: address(0xA55E7),
            fee: 3_000,
            tickSpacing: 60,
            hooks: address(0)
        });
    }

    function _poolId(LiquidityLibraryV4.PoolKey memory k) internal pure returns (bytes32) {
        return PoolId.unwrap(
            PoolIdLibrary.toId(
                CorePoolKey({
                    currency0: Currency.wrap(k.currency0),
                    currency1: Currency.wrap(k.currency1),
                    fee: k.fee,
                    tickSpacing: k.tickSpacing,
                    hooks: IHooks(k.hooks)
                })
            )
        );
    }

    // --- the arithmetic ---

    /// @dev At parity both virtual reserves equal `L`, so the cap is the reserve times half the budget. Half,
    ///      because sqrtPrice moves half as far as price and the budget is stated in price terms.
    function test_CapAtParityIsHalfTheBudgetOfDepth() public pure {
        uint128 liquidity = 1e21;

        uint256 sellingCurrency0 = LiquidityLibraryV4.maxInputForImpact(SQRT_ONE, liquidity, true, 100, DIVISOR);
        uint256 sellingCurrency1 = LiquidityLibraryV4.maxInputForImpact(SQRT_ONE, liquidity, false, 100, DIVISOR);

        assertEq(sellingCurrency0, 5e18, "1% of price is half a percent of sqrtPrice, so 50 bps of depth");
        assertEq(sellingCurrency1, sellingCurrency0, "at parity the two reserves are equal");
    }

    /// @dev The reserve that matters is the one being sold into: `L / sqrtP` of currency0, `L * sqrtP` of currency1.
    ///      With currency1 four times the price of currency0 there is half as much currency0 and twice as much
    ///      currency1, so the two caps differ by a factor of four.
    function test_CapFollowsTheReserveOfTheTokenBeingSold() public pure {
        uint160 sqrtFour = uint160(SQRT_ONE * 2);
        uint128 liquidity = 1e21;

        uint256 cap0 = LiquidityLibraryV4.maxInputForImpact(sqrtFour, liquidity, true, 100, DIVISOR);
        uint256 cap1 = LiquidityLibraryV4.maxInputForImpact(sqrtFour, liquidity, false, 100, DIVISOR);

        assertEq(cap0, 2.5e18, "reserve0 is L/2 here");
        assertEq(cap1, 10e18, "reserve1 is 2L here");
        assertEq(cap1, cap0 * 4);
    }

    /// @dev Both inputs are linear, which is the property that makes the cap predictable to operate: a pool twice as
    ///      deep absorbs twice the trade, and doubling the tolerance doubles what a single pass may move.
    function test_CapScalesWithDepthAndBudget() public pure {
        uint256 base = LiquidityLibraryV4.maxInputForImpact(SQRT_ONE, 1e21, true, 100, DIVISOR);

        assertEq(LiquidityLibraryV4.maxInputForImpact(SQRT_ONE, 2e21, true, 100, DIVISOR), base * 2, "twice the depth");
        assertEq(LiquidityLibraryV4.maxInputForImpact(SQRT_ONE, 1e21, true, 200, DIVISOR), base * 2, "twice the budget");
    }

    /// @dev Every degenerate input caps to zero rather than to something unbounded. Callers read zero as "no swap",
    ///      so an unreadable pool skips the trade instead of sending one with no size discipline at all.
    function test_UnreadablePoolOrEmptyBudgetCapsToZero() public pure {
        assertEq(LiquidityLibraryV4.maxInputForImpact(0, 1e21, true, 100, DIVISOR), 0, "no price");
        assertEq(LiquidityLibraryV4.maxInputForImpact(SQRT_ONE, 0, true, 100, DIVISOR), 0, "no depth");
        assertEq(LiquidityLibraryV4.maxInputForImpact(SQRT_ONE, 1e21, true, 0, DIVISOR), 0, "no budget");
        assertEq(LiquidityLibraryV4.maxInputForImpact(SQRT_ONE, 1e21, true, 100, 0), 0, "no divisor");
    }

    /// @dev The point of the cap: a trade trimmed to it stays inside its own budget. Liquidity is constant across
    ///      the move, so selling `x` of currency0 leaves `L / sqrtP' = L / sqrtP + x`, and the sqrtPrice drop is
    ///      `x / (reserve + x)` — at most half the budget. Price moves at most twice that, so the realised impact
    ///      stays under `budgetBps` with room to spare, which is the headroom the output floor then spends.
    function testFuzz_TrimmedTradeLeavesHeadroomUnderItsOwnFloor(uint128 liquidity, uint16 budgetBps) public pure {
        liquidity = uint128(bound(liquidity, 1e15, type(uint128).max / 2));
        budgetBps = uint16(bound(budgetBps, 1, 1_000));

        // sqrt(1) in Q96 is Q96 itself, so at parity the currency0 reserve `L / sqrtP` is exactly `L`.
        uint256 reserve = liquidity;
        uint256 cap = LiquidityLibraryV4.maxInputForImpact(SQRT_ONE, liquidity, true, budgetBps, DIVISOR);
        vm.assume(cap > 0);

        uint256 sqrtAfter = (uint256(SQRT_ONE) * reserve) / (reserve + cap);
        uint256 sqrtDrop = uint256(SQRT_ONE) - sqrtAfter;

        assertLe(sqrtDrop * 2 * DIVISOR, uint256(SQRT_ONE) * budgetBps, "sqrtPrice moved past half the budget");
    }

    /// @dev Exactly what it says, and no more. Trimming the input must not be a way around the anchor gate, which is
    ///      the only reference in the floor that this transaction cannot have moved. A tiny trade at a manipulated
    ///      spot is still refused, so the cap buys size discipline without weakening manipulation cover.
    function test_ImpactCapDoesNotReopenTheAnchorGate() public view {
        // Aged by a second and a block, so the only thing left to refuse the swap is the deviation itself.
        SwapGateLib.Anchor memory anchor = SwapGateLib.Anchor({
            tick: 0,
            has: true,
            time: uint64(block.timestamp) - 1,
            blockNumber: uint64(block.number) - 1
        });
        uint160 spot = uint160((uint256(SQRT_ONE) * 11) / 10);

        uint256 trimmed = LiquidityLibraryV4.maxInputForImpact(spot, 1e21, true, 100, DIVISOR);
        assertGt(trimmed, 0, "the cap itself is willing");
        // Pool tick 2,000 against an anchor at 0, well past a 200 tick allowance.
        assertEq(SwapGateLib.minOut(spot, 2_000, anchor, 200, true, true, trimmed, 100, DIVISOR, 3_000), 0);
    }

    // --- reading the pool ---

    /// @dev `swapInputCap` exists so the strategy pays a DELEGATECALL rather than two pool reads of its own. This
    ///      drives that path, so depth genuinely comes from the pool and not from a caller-supplied number.
    function test_SwapInputCapReadsDepthFromThePool() public {
        LiquidityLibraryV4.PoolKey memory k = _key();
        pm.setPool(_poolId(k), SQRT_ONE, 0, 1e21);

        assertEq(
            LiquidityLibraryV4.swapInputCap(IPoolManagerV4(address(pm)), k, true, 100, DIVISOR),
            LiquidityLibraryV4.maxInputForImpact(SQRT_ONE, 1e21, true, 100, DIVISOR)
        );
    }

    /// @dev An uninitialised or empty pool reads as zero depth, and a zero cap trims every trade to nothing. That is
    ///      the correct answer — there is no size at which a swap against no liquidity settles — but it also means a
    ///      caller must treat zero as "skip", never as "unbounded".
    function test_SwapInputCapIsZeroWithoutPoolLiquidity() public {
        LiquidityLibraryV4.PoolKey memory k = _key();

        assertEq(LiquidityLibraryV4.swapInputCap(IPoolManagerV4(address(pm)), k, true, 100, DIVISOR), 0, "unread pool");

        pm.setPool(_poolId(k), SQRT_ONE, 0, 0);
        assertEq(LiquidityLibraryV4.swapInputCap(IPoolManagerV4(address(pm)), k, true, 100, DIVISOR), 0, "empty pool");
    }
}
