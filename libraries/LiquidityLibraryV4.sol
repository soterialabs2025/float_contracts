// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IPositionManagerV4.sol";
import "../interfaces/IPoolManagerV4.sol";
import "./TickMath.sol";

/**
 * @title LiquidityLibraryV4
 * @notice Drop-in replacement for LiquidityLibrary targeting Uniswap V4.
 *
 * Key differences from V3 version:
 *  - No INonfungiblePositionManager (mint/collect/decrease).
 *    All position operations are sent to IPositionManagerV4.modifyLiquidities()
 *    as ABI-encoded action sequences.
 *  - No IUniswapV3Factory / pool address lookup.
 *    The pool is identified by a PoolKey struct; state is read via
 *    IPoolManagerV4 (StateLibrary pattern: getSlot0, getPositionLiquidity).
 *  - Fee collection uses the "zero-liquidity trick":
 *    DECREASE_LIQUIDITY(0) + TAKE_PAIR credits accrued fees.
 *  - Token approvals must target the V4 PositionManager (not NPM).
 *
 * Everything that was pure math (tick alignment, sqrt helpers,
 * getLiquidityForAmounts, getAmountsForLiquidity, calculateMinAmounts)
 * is identical to the V3 library – those functions are unchanged.
 */
library LiquidityLibraryV4 {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------
    // V4 Action constants  (matches Actions.sol in v4-periphery)
    // ---------------------------------------------------------------
    uint8 internal constant ACTION_MINT_POSITION      = 0x02;
    uint8 internal constant ACTION_INCREASE_LIQUIDITY = 0x00;
    uint8 internal constant ACTION_DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant ACTION_BURN_POSITION      = 0x03; // optional cleanup
    uint8 internal constant ACTION_SETTLE_PAIR        = 0x0d;
    uint8 internal constant ACTION_TAKE_PAIR          = 0x11;
    uint8 internal constant ACTION_CLOSE_CURRENCY     = 0x12;

    // FixedPoint96 constants (unchanged from V3 library)
    uint8   internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    // ---------------------------------------------------------------
    // Structs
    // ---------------------------------------------------------------

    /// @notice Tracks a single open V4 position. tokenId is the ERC-721 minted
    ///         by the V4 PositionManager; tickLower/tickUpper are cached locally
    ///         to avoid extra state reads.
    struct PositionState {
        uint256 positionId;   // ERC-721 token ID (0 = no open position)
        int24   tickLower;
        int24   tickUpper;
    }

    /// @notice Pool identification for V4. Passed in wherever a V3 pool address was used.
    struct PoolKey {
        address currency0;   // lower-sorted token (address(0) for native ETH)
        address currency1;   // higher-sorted token
        uint24  fee;
        int24   tickSpacing;
        address hooks;       // address(0) for no-hook pools
    }

    struct MintContext {
        IPositionManagerV4  posm;
        IPoolManagerV4      poolManager;
        PoolKey             poolKey;
        int24               m;            // width multiplier (same meaning as V3)
        uint16              slippageBps;
        uint256             dust;
    }

    struct IncreaseContext {
        IPositionManagerV4  posm;
        IPoolManagerV4      poolManager;
        PoolKey             poolKey;
        uint16              slippageBps;
        uint256             dust;
    }

    struct DecreaseContext {
        IPositionManagerV4  posm;
        IPoolManagerV4      poolManager;
        PoolKey             poolKey;
    }

    // ---------------------------------------------------------------
    // Tick alignment helpers  (IDENTICAL to V3 library)
    // ---------------------------------------------------------------

    function alignDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        return r == 0 ? tick : (tick < 0 ? tick - r - spacing : tick - r);
    }

    function alignUp(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        return r == 0 ? tick : (tick < 0 ? tick - r : tick + (spacing - r));
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = y;
        z = (x + 1) >> 1;
        while (z < x) {
            x = z;
            z = (y / z + z) >> 1;
        }
        return x;
    }

    function sqrt1e18(uint256 x1e18) internal pure returns (uint256) {
        uint256 maxSafeX1e18 = type(uint256).max / 1e18;
        if (x1e18 > maxSafeX1e18) {
            uint256 sqrtX = sqrt(x1e18);
            if (sqrtX > type(uint256).max / 1e18) revert("sqrt1e18: result overflow");
            return sqrtX * 1e18;
        }
        unchecked { return sqrt(x1e18 * 1e18); }
    }

    function getSqrtRatios(int24 lowerTick, int24 upperTick)
        internal pure returns (uint160 sqrtL, uint160 sqrtU)
    {
        sqrtL = TickMath.getSqrtRatioAtTick(lowerTick);
        sqrtU = TickMath.getSqrtRatioAtTick(upperTick);
    }

    function calculateMinAmounts(uint256 amount0, uint256 amount1, uint16 slippageBps)
        internal pure returns (uint256 min0, uint256 min1)
    {
        require(slippageBps <= 10_000, "slippageBps > 100%");
        uint256 slippage0 = Math.mulDiv(amount0, slippageBps, 10_000);
        uint256 slippage1 = Math.mulDiv(amount1, slippageBps, 10_000);
        min0 = slippage0 >= amount0 ? 0 : amount0 - slippage0;
        min1 = slippage1 >= amount1 ? 0 : amount1 - slippage1;
    }

    // ---------------------------------------------------------------
    // LiquidityAmounts math  (IDENTICAL to V3 library)
    // ---------------------------------------------------------------

    function toUint128(uint256 x) private pure returns (uint128 y) {
        require((y = uint128(x)) == x);
    }

    function getLiquidityForAmount0(
        uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = Math.mulDiv(sqrtRatioAX96, sqrtRatioBX96, Q96);
        return toUint128(Math.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function getLiquidityForAmount1(
        uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return toUint128(Math.mulDiv(amount1, Q96, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function getLiquidityForAmounts(
        uint160 sqrtRatioX96, uint160 sqrtRatioAX96, uint160 sqrtRatioBX96,
        uint256 amount0, uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            liquidity = getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtRatioX96, sqrtRatioBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioX96, amount1);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
        }
    }

    function getAmount0ForLiquidity(
        uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return Math.mulDiv(uint256(liquidity) << RESOLUTION, sqrtRatioBX96 - sqrtRatioAX96, sqrtRatioBX96) / sqrtRatioAX96;
    }

    function getAmount1ForLiquidity(
        uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return Math.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96);
    }

    function getAmountsForLiquidity(
        uint160 sqrtRatioX96, uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }

    // ---------------------------------------------------------------
    // V4 pool state helpers
    // ---------------------------------------------------------------

    /// @notice Compute the V4 PoolId (keccak256 of ABI-encoded PoolKey).
    function poolId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    /// @notice Read (sqrtPriceX96, currentTick) from the V4 PoolManager.
    /// @dev Replaces pool.slot0() from V3.
    function getSlot0(IPoolManagerV4 poolManager, PoolKey memory key)
        internal view returns (uint160 sqrtPriceX96, int24 tick)
    {
        (sqrtPriceX96, tick, , ) = poolManager.getSlot0(poolId(key));
    }

    /// @notice Same as `getSlot0`, but returns `(0, 0)` if the pool is uninitialized or `getSlot0` reverts.
    /// @dev Used by strategy **view** helpers (`balanceOfIdle`, `poolValue`) before the first mint so vault
    ///      `deposit` gas estimation does not revert when `sqrtPriceX96` is not yet readable for the key.
    function getSlot0Safe(IPoolManagerV4 poolManager, PoolKey memory key)
        internal view returns (uint160 sqrtPriceX96, int24 tick)
    {
        try poolManager.getSlot0(poolId(key)) returns (uint160 s, int24 t, uint24, uint24) {
            return (s, t);
        } catch {
            return (0, 0);
        }
    }

    /// @notice Read the liquidity of our position from the V4 PoolManager.
    /// @dev In V4, position liquidity is keyed by (poolId, owner, tickLower, tickUpper, salt).
    ///      The salt is the tokenId cast to bytes32, matching the PositionManager convention.
    function getPositionLiquidity(
        PositionState storage ps,
        IPositionManagerV4 posm
    ) internal view returns (uint128 liquidity) {
        if (ps.positionId == 0) return 0;
        return posm.getPositionLiquidity(ps.positionId);
    }

    // ---------------------------------------------------------------
    // Position Management  (V4 action-encoded calls)
    // ---------------------------------------------------------------

    /**
     * @notice Mint a new V4 concentrated liquidity position.
     * @dev Replaces LiquidityLibrary.mintNewPosition for V3.
     *      Reads sqrtPrice once (fixing the double-slot0 bug from V3 library),
     *      computes tick range, then calls posm.modifyLiquidities with
     *      [MINT_POSITION, SETTLE_PAIR].
     */
    function mintNewPosition(
        PositionState storage ps,
        MintContext memory ctx,
        uint256 bal0,   // balance of currency0 held by caller
        uint256 bal1    // balance of currency1 held by caller
    ) internal returns (uint256 newTokenId, uint128 newLiquidity) {
        if (bal0 == 0 && bal1 == 0) return (0, 0);

        // Read state ONCE (fixes double-slot0 race in V3 library)
        (uint160 sqrtP, int24 currentTick) = getSlot0(ctx.poolManager, ctx.poolKey);
        require(sqrtP != 0, "Pool not initialized");

        // Compute tick range  (identical logic to V3 library)
        int24 base  = alignDown(currentTick, ctx.poolKey.tickSpacing);
        int24 total = int24(int256(ctx.m) * int256(ctx.poolKey.tickSpacing));
        require(total > 0, "width=0");
        int24 lower;
        int24 upper;
        if (ctx.m % 2 == 0) {
            lower = base - (ctx.m / 2) * ctx.poolKey.tickSpacing;
            upper = base + (ctx.m / 2) * ctx.poolKey.tickSpacing;
        } else {
            lower = base - ((ctx.m - 1) / 2) * ctx.poolKey.tickSpacing;
            upper = lower + total;
        }
        int24 minTick = alignUp(TickMath.MIN_TICK, ctx.poolKey.tickSpacing);
        int24 maxTick = alignDown(TickMath.MAX_TICK, ctx.poolKey.tickSpacing);
        if (lower < minTick) lower = minTick;
        if (upper > maxTick) upper = maxTick;
        if (lower >= upper) { lower -= ctx.poolKey.tickSpacing; upper += ctx.poolKey.tickSpacing; }
        require(lower < upper, "bad ticks");

        ps.tickLower = lower;
        ps.tickUpper = upper;

        (uint160 sqrtL, uint160 sqrtU) = getSqrtRatios(lower, upper);

        uint128 liq = getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, bal0, bal1);
        require(liq > 0, "no liq");

        (uint256 need0, uint256 need1) = getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liq);
        if (need0 > bal0) need0 = bal0;
        if (need1 > bal1) need1 = bal1;
        // V4 PositionManager uses amount0Max / amount1Max (max tokens to spend),
        // not desired + min like V3. We apply slippage as the tolerance above need.
        uint256 max0 = need0 + Math.mulDiv(need0, ctx.slippageBps, 10_000);
        uint256 max1 = need1 + Math.mulDiv(need1, ctx.slippageBps, 10_000);

        // Peek at nextTokenId before minting so we can return it
        uint256 expectedTokenId = ctx.posm.nextTokenId();

        // Encode [MINT_POSITION, SETTLE_PAIR]
        bytes memory actions = abi.encodePacked(ACTION_MINT_POSITION, ACTION_SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            ctx.poolKey,
            lower,
            upper,
            liq,
            uint128(max0 > type(uint128).max ? type(uint128).max : max0),
            uint128(max1 > type(uint128).max ? type(uint128).max : max1),
            address(this),   // recipient of NFT = strategy contract
            bytes("")        // no hook data
        );
        params[1] = abi.encode(ctx.poolKey.currency0, ctx.poolKey.currency1);

        ctx.posm.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 300
        );

        // Confirm tokenId was actually minted
        uint256 mintedId = expectedTokenId;
        uint128 mintedLiq = ctx.posm.getPositionLiquidity(mintedId);
        if (mintedLiq == 0) return (0, 0);

        ps.positionId  = mintedId;
        newTokenId     = mintedId;
        newLiquidity   = mintedLiq;
    }

    /**
     * @notice Add liquidity to an existing V4 position.
     * @dev Replaces V3 increaseLiquidityInternal.
     *      Uses [INCREASE_LIQUIDITY, CLOSE_CURRENCY, CLOSE_CURRENCY] so that
     *      any accumulated fees are naturally absorbed as part of settlement.
     */
    function increaseLiquidityInternal(
        PositionState storage ps,
        IncreaseContext memory ctx,
        IERC20 token0,
        IERC20 token1
    ) internal returns (uint128 addedLiquidity) {
        if (ps.positionId == 0) return 0;

        (uint160 sqrtP, ) = getSlot0(ctx.poolManager, ctx.poolKey);
        (uint160 sqrtL, uint160 sqrtU) = getSqrtRatios(ps.tickLower, ps.tickUpper);

        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        if (bal0 < ctx.dust && bal1 < ctx.dust) return 0;

        uint128 liq = getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, bal0, bal1);
        if (liq == 0) return 0;

        (uint256 need0, uint256 need1) = getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liq);
        if (need0 > bal0) need0 = bal0;
        if (need1 > bal1) need1 = bal1;
        uint256 max0 = need0 + Math.mulDiv(need0, ctx.slippageBps, 10_000);
        uint256 max1 = need1 + Math.mulDiv(need1, ctx.slippageBps, 10_000);

        uint128 liquidityBefore = getPositionLiquidity(ps, ctx.posm);

        // [INCREASE_LIQUIDITY, CLOSE_CURRENCY x2]
        // CLOSE_CURRENCY handles whichever direction the delta falls (pay or receive),
        // which also implicitly collects any accrued fees.
        bytes memory actions = abi.encodePacked(
            ACTION_INCREASE_LIQUIDITY,
            ACTION_CLOSE_CURRENCY,
            ACTION_CLOSE_CURRENCY
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ps.positionId,
            liq,
            uint128(max0 > type(uint128).max ? type(uint128).max : max0),
            uint128(max1 > type(uint128).max ? type(uint128).max : max1),
            bytes("") // no hook data
        );
        params[1] = abi.encode(ctx.poolKey.currency0);
        params[2] = abi.encode(ctx.poolKey.currency1);

        ctx.posm.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 1200
        );

        uint128 liquidityAfter = getPositionLiquidity(ps, ctx.posm);
        addedLiquidity = liquidityAfter > liquidityBefore
            ? liquidityAfter - liquidityBefore
            : 0;
    }

    /**
     * @notice Collect all accrued fees without removing principal liquidity.
     * @dev V4 has no explicit collect(). The standard pattern is to call
     *      DECREASE_LIQUIDITY with liquidityDelta=0 (which snapshots fees)
     *      followed by TAKE_PAIR to pull the fee tokens out.
     * @return amount0 fee tokens for currency0
     * @return amount1 fee tokens for currency1
     */
    function collectAllFees(
        PositionState storage ps,
        DecreaseContext memory ctx,
        address recipient
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (ps.positionId == 0) return (0, 0);

        uint256 bal0Before = IERC20(ctx.poolKey.currency0).balanceOf(recipient);
        uint256 bal1Before = IERC20(ctx.poolKey.currency1).balanceOf(recipient);

        // Zero-liquidity trick: decreasing by 0 credits fees to the delta
        bytes memory actions = abi.encodePacked(
            ACTION_DECREASE_LIQUIDITY,
            ACTION_TAKE_PAIR
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            ps.positionId,
            uint256(0),  // liquidityDelta = 0 => fees only
            uint128(0),  // amount0Min
            uint128(0),  // amount1Min
            bytes("")    // no hook data
        );
        params[1] = abi.encode(ctx.poolKey.currency0, ctx.poolKey.currency1, recipient);

        ctx.posm.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 300
        );

        amount0 = IERC20(ctx.poolKey.currency0).balanceOf(recipient) - bal0Before;
        amount1 = IERC20(ctx.poolKey.currency1).balanceOf(recipient) - bal1Before;
    }

    /**
     * @notice Remove all liquidity from a V4 position.
     * @dev Replaces decreaseAllLiquidity. Collects fees first (zero-liq trick),
     *      then removes full principal in one call.
     *      Uses amount0Min = amount1Min = 0 intentionally; callers that need
     *      slippage protection should compute min amounts before calling.
     */
    function decreaseAllLiquidity(
        PositionState storage ps,
        DecreaseContext memory ctx
    ) internal returns (uint128 totalRemoved) {
        if (ps.positionId == 0) return 0;
        uint128 liq = getPositionLiquidity(ps, ctx.posm);
        if (liq == 0) return 0;

        // [DECREASE_LIQUIDITY (full), TAKE_PAIR]
        bytes memory actions = abi.encodePacked(
            ACTION_DECREASE_LIQUIDITY,
            ACTION_TAKE_PAIR
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            ps.positionId,
            uint256(liq),
            uint128(0), // amount0Min
            uint128(0), // amount1Min
            bytes("")
        );
        params[1] = abi.encode(ctx.poolKey.currency0, ctx.poolKey.currency1, address(this));

        ctx.posm.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 300
        );

        totalRemoved = liq;
    }

    /**
     * @notice Remove a specific liquidity amount from a V4 position.
     * @dev Replaces decreaseLiquidityByAmount.
     */
    function decreaseLiquidityByAmount(
        PositionState storage ps,
        DecreaseContext memory ctx,
        uint128 liqToRemove
    ) internal returns (uint128 removed) {
        if (ps.positionId == 0) return 0;
        if (liqToRemove == 0) return 0;

        bytes memory actions = abi.encodePacked(
            ACTION_DECREASE_LIQUIDITY,
            ACTION_TAKE_PAIR
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            ps.positionId,
            uint256(liqToRemove),
            uint128(0),
            uint128(0),
            bytes("")
        );
        params[1] = abi.encode(ctx.poolKey.currency0, ctx.poolKey.currency1, address(this));

        ctx.posm.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 300
        );

        removed = liqToRemove;
    }
}
