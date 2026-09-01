// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IPositionManagerV4.sol";
import "../interfaces/IPoolManagerV4.sol";
import "../../v4/libraries/TickMath.sol";
import {PoolKey as CorePoolKey} from "../../../lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "../../../lib/v4-core/src/types/Currency.sol";
import {IHooks} from "../../../lib/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "../../../lib/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "../../../lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "../../../lib/v4-core/src/libraries/StateLibrary.sol";

interface IV4PoolConfigSource {
    function getV4PoolConfig(address assetAddress) external view returns (CorePoolKey memory key, bytes memory hookData);
}

library LiquidityLibraryV4 {
    using SafeERC20 for IERC20;

    error SqrtOverflow();
    error SlippageTooHigh();
    error PoolNotInitialized();
    error ZeroWidth();
    error BadTicks();
    error NoLiquidity();
    error Uint128Overflow();

    uint8 internal constant ACTION_MINT_POSITION      = 0x02;
    uint8 internal constant ACTION_INCREASE_LIQUIDITY = 0x00;
    uint8 internal constant ACTION_DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant ACTION_BURN_POSITION      = 0x03; 
    uint8 internal constant ACTION_SETTLE_PAIR        = 0x0d;
    uint8 internal constant ACTION_TAKE_PAIR          = 0x11;
    uint8 internal constant ACTION_CLOSE_CURRENCY     = 0x12;

    uint8   internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;


    struct PositionState {
        uint256 positionId;     
        int24   tickLower;
        int24   tickUpper;
    }

    struct PoolKey {
        address currency0;   
        address currency1;   
        uint24  fee;
        int24   tickSpacing;
        address hooks;       
    }

    struct MintContext {
        IPositionManagerV4  posm;
        IPoolManagerV4      poolManager;
        PoolKey             poolKey;
        int24               m;            
        uint16              slippageBps;
        uint256             dust;
        bytes               hookData;
    }

    struct IncreaseContext {
        IPositionManagerV4  posm;
        IPoolManagerV4      poolManager;
        PoolKey             poolKey;
        uint16              slippageBps;
        uint256             dust;
        bytes               hookData;
    }

    struct DecreaseContext {
        IPositionManagerV4  posm;
        IPoolManagerV4      poolManager;
        PoolKey             poolKey;
        bytes               hookData;
    }


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
            if (sqrtX > type(uint256).max / 1e18) revert SqrtOverflow();
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
        if (slippageBps > 10_000) revert SlippageTooHigh();
        uint256 slippage0 = Math.mulDiv(amount0, slippageBps, 10_000);
        uint256 slippage1 = Math.mulDiv(amount1, slippageBps, 10_000);
        min0 = slippage0 >= amount0 ? 0 : amount0 - slippage0;
        min1 = slippage1 >= amount1 ? 0 : amount1 - slippage1;
    }

    function toUint128(uint256 x) private pure returns (uint128 y) {
        if ((y = uint128(x)) != x) revert Uint128Overflow();
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

    function fromCorePoolKey(CorePoolKey memory key) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.unwrap(key.currency0),
            currency1: Currency.unwrap(key.currency1),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: address(key.hooks)
        });
    }

    function poolKeyFromRouter(IV4PoolConfigSource router, address asset)
        internal
        view
        returns (PoolKey memory)
    {
        (CorePoolKey memory routerKey,) = router.getV4PoolConfig(asset);
        return fromCorePoolKey(routerKey);
    }

    function poolId(PoolKey memory key) internal pure returns (bytes32) {
        CorePoolKey memory ck = CorePoolKey({
            currency0: Currency.wrap(key.currency0),
            currency1: Currency.wrap(key.currency1),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: IHooks(key.hooks)
        });
        return PoolId.unwrap(PoolIdLibrary.toId(ck));
    }
    function getSlot0(IPoolManagerV4 poolManager, PoolKey memory key)
        internal view returns (uint160 sqrtPriceX96, int24 tick)
    {
        (sqrtPriceX96, tick, , ) =
            StateLibrary.getSlot0(IPoolManager(address(poolManager)), PoolId.wrap(poolId(key)));
    }

    function getSlot0Safe(IPoolManagerV4 poolManager, PoolKey memory key)
        internal view returns (uint160 sqrtPriceX96, int24 tick)
    {
        return getSlot0(poolManager, key);
    }


    function getPositionLiquidity(
        PositionState storage ps,
        IPositionManagerV4 posm
    ) internal view returns (uint128 liquidity) {
        if (ps.positionId == 0) return 0;
        return posm.getPositionLiquidity(ps.positionId);
    }


    function mintNewPosition(
        PositionState storage ps,
        MintContext memory ctx,
        uint256 bal0,   
        uint256 bal1    
    ) internal returns (uint256 newTokenId, uint128 newLiquidity) {
        if (bal0 == 0 && bal1 == 0) return (0, 0);

        (uint160 sqrtP, int24 currentTick) = getSlot0(ctx.poolManager, ctx.poolKey);
        if (sqrtP == 0) revert PoolNotInitialized();

        int24 base  = alignDown(currentTick, ctx.poolKey.tickSpacing);
        int24 total = int24(int256(ctx.m) * int256(ctx.poolKey.tickSpacing));
        if (total <= 0) revert ZeroWidth();
        int24 lower;
        int24 upper;
        if (ctx.m % 2 == 0) {
            lower = base - (ctx.m / 2) * ctx.poolKey.tickSpacing;
            upper = base + (ctx.m / 2) * ctx.poolKey.tickSpacing;
        } else {
            lower = base - ((ctx.m - 1) / 2) * ctx.poolKey.tickSpacing;
            upper = lower + total;
        }
        return mintNewPositionWithRange(ps, ctx, bal0, bal1, lower, upper);
    }

    function mintNewPositionWithRange(
        PositionState storage ps,
        MintContext memory ctx,
        uint256 bal0,
        uint256 bal1,
        int24 lower,
        int24 upper
    ) public returns (uint256 newTokenId, uint128 newLiquidity) {
        if (bal0 == 0 && bal1 == 0) return (0, 0);

        (uint160 sqrtP, ) = getSlot0(ctx.poolManager, ctx.poolKey);
        if (sqrtP == 0) revert PoolNotInitialized();

        int24 spacing = ctx.poolKey.tickSpacing;
        int24 minTick = alignUp(TickMath.MIN_TICK, spacing);
        int24 maxTick = alignDown(TickMath.MAX_TICK, spacing);
        if (lower < minTick) lower = minTick;
        if (upper > maxTick) upper = maxTick;
        if (lower >= upper) { lower -= spacing; upper += spacing; }
        if (lower >= upper) revert BadTicks();

        ps.tickLower = lower;
        ps.tickUpper = upper;

        (uint160 sqrtL, uint160 sqrtU) = getSqrtRatios(lower, upper);

        uint128 liq = getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, bal0, bal1);
        if (liq == 0) revert NoLiquidity();

        (uint256 need0, uint256 need1) = getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liq);
        if (need0 > bal0) need0 = bal0;
        if (need1 > bal1) need1 = bal1;
        uint256 max0 = need0 + Math.mulDiv(need0, ctx.slippageBps, 10_000);
        uint256 max1 = need1 + Math.mulDiv(need1, ctx.slippageBps, 10_000);

        uint256 expectedTokenId = ctx.posm.nextTokenId();

        bytes memory actions = abi.encodePacked(ACTION_MINT_POSITION, ACTION_SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            ctx.poolKey,
            lower,
            upper,
            liq,
            uint128(max0 > type(uint128).max ? type(uint128).max : max0),
            uint128(max1 > type(uint128).max ? type(uint128).max : max1),
            address(this),
            ctx.hookData
        );
        params[1] = abi.encode(ctx.poolKey.currency0, ctx.poolKey.currency1);

        ctx.posm.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 300
        );

        uint256 mintedId = expectedTokenId;
        uint128 mintedLiq = ctx.posm.getPositionLiquidity(mintedId);
        if (mintedLiq == 0) return (0, 0);

        ps.positionId  = mintedId;
        newTokenId     = mintedId;
        newLiquidity   = mintedLiq;
    }
    /// @param amount0Max Cap for token0 (e.g. deployable); also capped to on-strategy balance.
    /// @param amount1Max Cap for token1 (e.g. deployable); also capped to on-strategy balance.
    function increaseLiquidityInternal(
        PositionState storage ps,
        IncreaseContext memory ctx,
        IERC20 token0,
        IERC20 token1,
        uint256 amount0Max,
        uint256 amount1Max
    ) public returns (uint128 addedLiquidity) {
        if (ps.positionId == 0) return 0;

        (uint160 sqrtP, ) = getSlot0(ctx.poolManager, ctx.poolKey);
        (uint160 sqrtL, uint160 sqrtU) = getSqrtRatios(ps.tickLower, ps.tickUpper);

        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        if (amount0Max < bal0) bal0 = amount0Max;
        if (amount1Max < bal1) bal1 = amount1Max;
        if (bal0 < ctx.dust && bal1 < ctx.dust) return 0;

        uint128 liq = getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, bal0, bal1);
        if (liq == 0) return 0;

        (uint256 need0, uint256 need1) = getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liq);
        if (need0 > bal0) {
            liq = toUint128(Math.mulDiv(uint256(liq), bal0, need0));
        } else if (need1 > bal1) {
            liq = toUint128(Math.mulDiv(uint256(liq), bal1, need1));
        }
        if (liq == 0) return 0;
        (need0, need1) = getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liq);
        if (need0 > bal0) {
            liq = toUint128(Math.mulDiv(uint256(liq), bal0, need0));
            (need0, need1) = getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liq);
        }
        if (need1 > bal1) {
            liq = toUint128(Math.mulDiv(uint256(liq), bal1, need1));
            (need0, need1) = getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liq);
        }
        if (liq == 0 || need0 > bal0 || need1 > bal1) return 0;

        uint256 max0 = need0 + Math.mulDiv(need0, ctx.slippageBps, 10_000);
        uint256 max1 = need1 + Math.mulDiv(need1, ctx.slippageBps, 10_000);

        uint128 liquidityBefore = getPositionLiquidity(ps, ctx.posm);

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
            ctx.hookData
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

    function collectAllFees(
        PositionState storage ps,
        DecreaseContext memory ctx,
        address recipient
    ) public returns (uint256 amount0, uint256 amount1) {
        if (ps.positionId == 0) return (0, 0);

        uint256 bal0Before = IERC20(ctx.poolKey.currency0).balanceOf(recipient);
        uint256 bal1Before = IERC20(ctx.poolKey.currency1).balanceOf(recipient);

        bytes memory actions = abi.encodePacked(
            ACTION_DECREASE_LIQUIDITY,
            ACTION_TAKE_PAIR
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            ps.positionId,
            uint256(0),  
            uint128(0),  
            uint128(0),  
            ctx.hookData
        );
        params[1] = abi.encode(ctx.poolKey.currency0, ctx.poolKey.currency1, recipient);

        ctx.posm.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 300
        );

        amount0 = IERC20(ctx.poolKey.currency0).balanceOf(recipient) - bal0Before;
        amount1 = IERC20(ctx.poolKey.currency1).balanceOf(recipient) - bal1Before;
    }

    function decreaseAllLiquidity(
        PositionState storage ps,
        DecreaseContext memory ctx
    ) public returns (uint128 totalRemoved) {
        if (ps.positionId == 0) return 0;
        uint128 liq = getPositionLiquidity(ps, ctx.posm);
        if (liq == 0) return 0;

        bytes memory actions = abi.encodePacked(
            ACTION_DECREASE_LIQUIDITY,
            ACTION_TAKE_PAIR
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            ps.positionId,
            uint256(liq),
            uint128(0), 
            uint128(0), 
            ctx.hookData
        );
        params[1] = abi.encode(ctx.poolKey.currency0, ctx.poolKey.currency1, address(this));

        ctx.posm.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 300
        );

        totalRemoved = liq;
    }

    function decreaseLiquidityByAmount(
        PositionState storage ps,
        DecreaseContext memory ctx,
        uint128 liqToRemove
    ) public returns (uint128 removed) {
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
            ctx.hookData
        );
        params[1] = abi.encode(ctx.poolKey.currency0, ctx.poolKey.currency1, address(this));

        ctx.posm.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 300
        );

        removed = liqToRemove;
    }
}
