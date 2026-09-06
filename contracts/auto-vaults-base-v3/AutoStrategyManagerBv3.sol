// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/AutoBandLib.sol";

/// @title AutoStrategyManagerBv3
/// @notice Owner-settable params for AutoStrategyV2 (dual-bucket reserve + Auto bands).
contract AutoStrategyManagerBv3 is Ownable {
    constructor() Ownable(msg.sender) {}

    uint256 public constant DIVISOR = 10_000;
    /// @notice Balances at or below this are ignored as dust rather than swapped or deployed.
    uint256 internal constant LIQUIDITY_DUST = 1_000_000_000_000;
    /// @notice ASSET share target for balance / reserve deficit pull (default 5000 = 50/50).
    uint256 public targetAssetBps = 5000;

    int24 public tickSpacing = 200;
    uint256 public rangeBelowTicks = 800;
    uint256 public rangeAboveTicks = 800;
    uint256 public innerBelowTicks = 600;
    uint256 public innerAboveTicks = 600;

    uint16 public slippageBps = 100;
    uint256 public minHarvestDelay = 2 hours;
    uint256 public withdrawalFeeBps = 100;
    /// @notice Share of fee-only collects sent to `feeManager` (default 600 = 6%).
    uint256 public protocolFeeBps = 600;
    /// @notice Share of post-protocol deposit/fee capital kept idle as reserve (default 5000 = 50%).
    uint256 public reserveBps = 5000;
    /// @notice Share of protocolFeeBps proceeds sent to ShareStaking (rest to feeManager). Default 50%.
    uint256 public stakingShareBps = 5000;
    /// @notice True after TBA/post-transfer owner calls `setStakingShareBps` once; cannot change again.
    bool public stakingShareBpsLocked;
    /// @notice Uniswap V3 oracle window for rebalance TWAP and swap floors (default 30 minutes).
    uint32 public twapSeconds = 30 minutes;
    /// @notice Max |spot − TWAP| / TWAP in bps before `_balanceTokens` / reserve deficit pulls skip (default 3%).
    uint256 public maxTwapDeviationBps = 300;
    /// @notice Withdrawals price against this multiple of `maxTwapDeviationBps` so ordinary volatility cannot
    ///         trap users. Rebalances keep the tighter band because skipping one costs nothing.
    uint256 internal constant WITHDRAW_DEVIATION_MULTIPLE = 3;
    /// @notice Haircut applied to the TWAP-derived swap floor passed to the router (default 1%).
    /// @dev Distinct from `slippageBps`, which bounds LP mint amounts.
    uint16 public swapSlippageBps = 200;

    /// @notice Set reserve peel bps. No cap — `> DIVISOR` peels all deployable (no LP mint).
    function setReserveBps(uint256 bps) external onlyOwner {
        reserveBps = bps;
    }

    /// @notice Set ASSET inventory target bps. No cap — `0` = all WETH, `> DIVISOR` = all ASSET.
    function setTargetAssetBps(uint256 bps) external onlyOwner {
        targetAssetBps = bps;
    }

    /// @notice One-time set of staking/feeManager split. Only after package → TBA ownership lock.
    /// @dev Deployer cannot change the default (7500). TBA may set once, then `stakingShareBpsLocked`.
    function setStakingShareBps(uint256 bps) external onlyOwner {
        if (!_stakingShareBpsEditable() || stakingShareBpsLocked || bps > DIVISOR) revert StakingShareBps();
        stakingShareBps = bps;
        stakingShareBpsLocked = true;
    }

    /// @notice Set the TWAP window used for rebalance pricing and swap floors.
    /// @dev Zero is rejected. Swap floors are priced off this oracle, so disabling it would leave `_swap` unable
    ///      to price anything and revert every withdrawal. Shorten the window to loosen the gate instead.
    function setTwapSeconds(uint32 seconds_) external onlyOwner {
        if (seconds_ < 60 || seconds_ > 1 days) revert TwapConfig();
        twapSeconds = seconds_;
    }

    /// @notice Set max spot vs TWAP deviation for rebalance and swap floors.
    /// @dev Capped well below `DIVISOR`: at 100% the gate always passes, silently disabling the only price check.
    function setMaxTwapDeviationBps(uint256 bps) external onlyOwner {
        if (bps > 1_000) revert TwapConfig();
        maxTwapDeviationBps = bps;
    }

    /// @notice Set the haircut on TWAP-derived swap floors. Capped so a floor can never be driven to zero.
    function setSwapSlippageBps(uint16 bps) external onlyOwner {
        if (bps > 1_000) revert TwapConfig();
        swapSlippageBps = bps;
    }

    /// @dev Strategy overrides: true after factory package ownership transfer (TBA).
    function _stakingShareBpsEditable() internal view virtual returns (bool) {
        return false;
    }

    error StakingShareBps();
    error TwapConfig();

    function _spacing() internal view returns (int24) {
        int24 sp = tickSpacing;
        return sp > 0 ? sp : int24(200);
    }

    function _initAutoDefaults() internal {
        tickSpacing = 200;
        rangeBelowTicks = 800;
        rangeAboveTicks = 800;
        innerBelowTicks = 600;
        innerAboveTicks = 600;
        slippageBps = 100;
        minHarvestDelay = 2 hours;
        withdrawalFeeBps = 100;
        protocolFeeBps = 600;
        reserveBps = 5000;
        targetAssetBps = 5000;
        stakingShareBps = 5000;
        stakingShareBpsLocked = false;
        twapSeconds = 30 minutes;
        maxTwapDeviationBps = 300;
        swapSlippageBps = 100;
    }

    function setRangeParams(uint256 _rangeBelowTicks, uint256 _rangeAboveTicks) external onlyOwner {
        if (tickSpacing == 0) tickSpacing = _spacing();
        rangeBelowTicks = _rangeBelowTicks;
        rangeAboveTicks = _rangeAboveTicks;
        AutoBandLib.requireInnerWithinOuter(rangeBelowTicks, rangeAboveTicks, innerBelowTicks, innerAboveTicks);
    }

    function setInnerBandParams(uint256 _innerBelowTicks, uint256 _innerAboveTicks) external onlyOwner {
        if (tickSpacing == 0) tickSpacing = _spacing();
        AutoBandLib.requireInnerWithinOuter(rangeBelowTicks, rangeAboveTicks, _innerBelowTicks, _innerAboveTicks);
        innerBelowTicks = _innerBelowTicks;
        innerAboveTicks = _innerAboveTicks;
    }


}
