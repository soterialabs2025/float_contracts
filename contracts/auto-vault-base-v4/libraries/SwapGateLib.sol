// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SwapGateLib
/// @notice Manipulation gate and output floor for strategy-initiated swaps.
/// @dev Functions are `public` so this deploys once and links by address rather than inlining into every
///      strategy. AutoStrategyBv4 sits against the EIP-170 runtime limit and this is the largest block of
///      pricing math in it that needs no strategy storage.
library SwapGateLib {
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

    /// @notice Price of the non-WETH side in WETH terms, 1e18 scaled. Zero when the pool is uninitialised.
    function spotPrice1e18(uint160 sqrtPriceX96, bool wethIsCurrency0) public pure returns (uint256) {
        uint256 price = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), (uint256(1) << 192) / 1e18);
        if (wethIsCurrency0) return price;
        if (price == 0) return 0;
        return Math.mulDiv(1e18, 1e18, price);
    }

    /// @notice Output floor for a swap of `amount`, or zero when the caller must skip the swap.
    /// @dev The anchor is the one price reference here that the current transaction cannot have moved, so it is
    ///      what bounds gross manipulation. The spot-derived floor cannot, since it reads the pool being traded
    ///      against. Callers must treat a zero return as "do not swap", not as "no minimum".
    function minOut(
        uint160 sqrtPriceX96,
        int24 poolTick,
        Anchor memory anchor,
        uint256 maxDeviation,
        bool wethIsCurrency0,
        bool tokenInIsWeth,
        uint256 amount,
        uint256 slippageBps,
        uint256 divisor
    ) public view returns (uint256) {
        if (sqrtPriceX96 == 0) return 0;
        if (anchor.has) {
            // Anchored this block, so it carries no information the caller could not have just created.
            if (block.number <= anchor.blockNumber) return 0;
            int256 dev = int256(poolTick) - int256(anchor.tick);
            if (dev < 0) dev = -dev;
            if (uint256(dev) > allowedTickDeviation(maxDeviation, block.timestamp - anchor.time)) return 0;
        }
        uint256 p = spotPrice1e18(sqrtPriceX96, wethIsCurrency0);
        if (p == 0) return 0;
        uint256 expected = tokenInIsWeth ? Math.mulDiv(amount, p, 1e18) : Math.mulDiv(amount, 1e18, p);
        return Math.mulDiv(expected, divisor - slippageBps, divisor);
    }
}
