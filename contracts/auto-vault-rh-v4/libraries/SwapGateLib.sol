// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "../../v4/libraries/TickMath.sol";

/// @title SwapGateLib
/// @notice Manipulation gate and output floor for strategy-initiated swaps.
/// @dev Functions are `public` so this deploys once and links by address rather than inlining into every
///      strategy. AutoStrategyBv4 sits against the EIP-170 runtime limit and this is the largest block of
///      pricing math in it that needs no strategy storage.
library SwapGateLib {
    /// @notice Denominator for v4 fees, which are quoted in pips (hundredths of a bip).
    uint256 internal constant PIPS = 1_000_000;

    /// @param tick Pool tick recorded when the anchor was written, aligned down to spacing.
    /// @param has False until the first band is minted, which leaves the gate open during bootstrap.
    /// @param time Anchor timestamp. The deviation allowance widens with its age.
    /// @param blockNumber Block the anchor was written in.
    struct Anchor {
        int24 tick;
        bool has;
        uint64 time;
        uint64 blockNumber;
    }

    /// @notice Ticks the pool may sit from the anchor before swaps are refused, widening with the anchor's age.
    /// @dev The widening is what stops a deadlock. On a large sustained move a fixed bound refuses the
    ///      rebalancing swap, the one-sided mint that follows yields no liquidity, and since the anchor is only
    ///      rewritten by a successful mint the refusal repeats indefinitely.
    function allowedTickDeviation(uint256 maxDeviation, uint256 anchorAge) public pure returns (uint256) {
        return maxDeviation + (maxDeviation * anchorAge) / 1 days;
    }

    /// @notice Amount of the opposite currency for `amount` of the base side at `sqrtRatioX96`.
    /// @dev Follows Uniswap's `OracleLibrary.getQuoteAtTick`: both precision branches and currency ordering
    ///      honoured, with `Math.mulDiv` supplying the 512-bit intermediate that `FullMath.mulDiv` does upstream.
    /// @dev A price quote only. It excludes the swap fee and any liquidity-based impact, which is why callers
    ///      deriving an output floor must subtract both.
    function quoteAtSqrt(uint160 sqrtRatioX96, uint256 amount, bool baseIsCurrency0) public pure returns (uint256) {
        if (sqrtRatioX96 == 0) return 0;
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return baseIsCurrency0
                ? Math.mulDiv(ratioX192, amount, 1 << 192)
                : Math.mulDiv(1 << 192, amount, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return baseIsCurrency0 ? Math.mulDiv(ratioX128, amount, 1 << 128) : Math.mulDiv(1 << 128, amount, ratioX128);
    }

    /// @notice ASSET per WETH, 1e18 scaled. Zero when the pool is uninitialised.
    function spotPrice1e18(uint160 sqrtPriceX96, bool wethIsCurrency0) public pure returns (uint256) {
        return quoteAtSqrt(sqrtPriceX96, 1e18, wethIsCurrency0);
    }

    /// @notice Ticks the price reference is allowed to have moved since it was last written.
    /// @dev Rate-limited per second, not per block. Writes land on a keeper cadence rather than on every swap,
    ///      so a per-block bound of the kind Uniswap's truncated oracle hook uses would say nothing here.
    /// @param maxRefDrift Ceiling on the allowance. Without it a neglected reference relaxes until it bounds
    ///        nothing; with it, a move larger than the ceiling stays untracked until the keeper returns.
    function refDrift(uint64 refTime, uint256 secondsPerRefTick, uint256 maxRefDrift)
        public
        view
        returns (uint256)
    {
        if (refTime == 0 || secondsPerRefTick == 0) return 0;
        if (block.timestamp <= refTime) return 0;
        uint256 drift = (block.timestamp - refTime) / secondsPerRefTick;
        return drift > maxRefDrift ? maxRefDrift : drift;
    }

    /// @notice `spotTick` truncated to within `drift` of `refTick`.
    /// @dev The truncation proper. A price that has run further than the reference could legitimately have
    ///      travelled is treated as though it had only travelled that far, so holding a manipulation for one
    ///      block moves nothing that matters.
    function clampTick(int24 spotTick, int24 refTick, uint256 drift) public pure returns (int24) {
        int256 d = int256(drift);
        int256 lo = int256(refTick) - d;
        int256 hi = int256(refTick) + d;
        if (lo < TickMath.MIN_TICK) lo = TickMath.MIN_TICK;
        if (hi > TickMath.MAX_TICK) hi = TickMath.MAX_TICK;
        if (int256(spotTick) < lo) return int24(lo);
        if (int256(spotTick) > hi) return int24(hi);
        return spotTick;
    }

    /// @notice ASSET per WETH at `tick`, 1e18 scaled.
    function priceAtTick(int24 tick, bool wethIsCurrency0) public pure returns (uint256) {
        return quoteAtSqrt(TickMath.getSqrtRatioAtTick(tick), 1e18, wethIsCurrency0);
    }

    /// @notice The tick a reference write should record: `spotTick` truncated to the drift earned since `refTime`.
    /// @dev Composed here rather than at the call site on purpose. Each library entry point the strategy calls
    ///      costs it a `DELEGATECALL` and its ABI encoding, and `AutoStrategyRhV4` has no room to spend three
    ///      where one will do.
    function nextRefTick(
        int24 spotTick,
        int24 refTick,
        uint64 refTime,
        uint256 secondsPerRefTick,
        uint256 maxRefDrift
    ) public view returns (int24) {
        if (refTime == 0) return spotTick;
        return clampTick(spotTick, refTick, refDrift(refTime, secondsPerRefTick, maxRefDrift));
    }

    /// @notice ASSET per WETH at the truncated reference, 1e18 scaled. Zero before the reference is seeded.
    function refPrice1e18(
        int24 spotTick,
        int24 refTick,
        uint64 refTime,
        uint256 secondsPerRefTick,
        uint256 maxRefDrift,
        bool wethIsCurrency0
    ) public view returns (uint256) {
        if (refTime == 0) return 0;
        return priceAtTick(
            clampTick(spotTick, refTick, refDrift(refTime, secondsPerRefTick, maxRefDrift)), wethIsCurrency0
        );
    }

    /// @notice Output floor for a swap of `amount`, or zero when the caller must skip the swap.
    /// @dev The anchor is the one price reference here that the current transaction cannot have moved, so it is
    ///      what bounds gross manipulation. The spot-derived floor cannot, since it reads the pool being traded
    ///      against. Callers must treat a zero return as "do not swap", not as "no minimum".
    /// @param swapFeePips Combined protocol and LP fee for this direction, in pips. See `PIPS`.
    /// @param slippageBps Tolerance for what cannot be known here: liquidity-based price impact, and drift
    ///        between reading the pool and executing against it.
    /// @dev Fee and tolerance are separate deductions because they are different things. The fee is an exact,
    ///      known charge the PoolManager takes off the input before the output is measured against this floor,
    ///      so a floor that ignores it can never be met and every swap reverts.
    function minOut(
        uint160 sqrtPriceX96,
        int24 poolTick,
        Anchor memory anchor,
        uint256 maxDeviation,
        bool wethIsCurrency0,
        bool tokenInIsWeth,
        uint256 amount,
        uint256 slippageBps,
        uint256 divisor,
        uint24 swapFeePips
    ) public view returns (uint256) {
        if (sqrtPriceX96 == 0) return 0;
        if (swapFeePips >= PIPS) return 0;
        if (anchor.has) {
            // Anchored this block, so it carries no information the caller could not have just created.
            if (block.number <= anchor.blockNumber) return 0;
            int256 dev = int256(poolTick) - int256(anchor.tick);
            if (dev < 0) dev = -dev;
            if (uint256(dev) > allowedTickDeviation(maxDeviation, block.timestamp - anchor.time)) return 0;
        }
        // `tokenIn` is currency0 exactly when its WETH-ness matches WETH's position in the pair.
        uint256 quote = quoteAtSqrt(sqrtPriceX96, amount, tokenInIsWeth == wethIsCurrency0);
        if (quote == 0) return 0;
        uint256 afterFee = Math.mulDiv(quote, PIPS - swapFeePips, PIPS);
        return Math.mulDiv(afterFee, divisor - slippageBps, divisor);
    }
}
