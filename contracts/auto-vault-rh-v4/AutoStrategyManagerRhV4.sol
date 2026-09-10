// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../v4/libraries/TrailingFloorLib.sol";
import "./libraries/AutoBandLib.sol";

/// @title AutoStrategyManagerRhV4
/// @notice Owner-settable params for AutoStrategyRhV4 (dual-bucket reserve + Auto bands).
contract AutoStrategyManagerRhV4 is Ownable {
    constructor() Ownable(msg.sender) {}

    /// @notice Per-package outer/inner band widths (tick distances). Must be multiples of pool tickSpacing.
    struct BandConfig {
        uint256 rangeBelowTicks;
        uint256 rangeAboveTicks;
        uint256 innerBelowTicks;
        uint256 innerAboveTicks;
    }

    uint256 public constant DIVISOR = 10_000;
    /// @notice ASSET share target for balance / reserve deficit pull (default 5000 = 50/50).
    uint256 public targetAssetBps = 5000;

    int24 public tickSpacing = 160;
    uint256 public rangeBelowTicks = 1120;
    uint256 public rangeAboveTicks = 1120;
    uint256 public innerBelowTicks = 960;
    uint256 public innerAboveTicks = 960;

    /// @notice Tolerance applied to LP mint and increase amounts.
    uint16 public slippageBps = 100;
    /// @notice Tolerance applied to the swap output floor, on top of the pool's own fee.
    /// @dev Separate from `slippageBps` so widening what a swap will accept does not also loosen LP minting.
    uint16 public swapSlippageBps = 100;
    /// @notice Withdrawals widen the floor haircut by this multiple, because a skipped rebalance retries whereas a
    ///         skipped exit swap pays the user in the token they did not ask for.
    /// @dev Safe to loosen only on the exit path. That swap sells the withdrawer's own pro-rata tokens and credits
    ///      the proceeds straight back to them, so a worse fill is charged to the caller who asked for it rather
    ///      than to the remaining holders. Pool movement — the part that does touch everyone — stays bounded by
    ///      `maxSwapTickDeviation` and the router's price-impact check, neither of which this relaxes.
    uint256 internal constant WITHDRAW_SLIPPAGE_MULTIPLE = 3;
    /// @dev Ceiling on the widened haircut. `setSwapSlippageBps` allows up to 1_000, and an unclamped multiple
    ///      would reach 30% — past which a floor no longer bounds execution in any useful way.
    uint256 internal constant MAX_WITHDRAW_SLIPPAGE_BPS = 1_000;
    uint256 public minHarvestDelay = 2 hours;
    uint256 public withdrawalFeeBps = 100;
    /// @notice Share of fee-only collects sent to protocol peel (default 600 = 6%).
    uint256 public protocolFeeBps = 600;
    /// @notice When false, `_collectAllFees` skips the protocol peel; `protocolFeeBps` is left as-is.
    bool public protocolFeeOn = true;
    /// @notice Share of post-protocol deposit/fee capital kept idle as reserve (default 5000 = 50%).
    uint256 public reserveBps = 5000;
    /// @notice Share of protocolFeeBps proceeds sent to ShareStaking (rest to feeManager). Default 50%.
    uint256 public stakingShareBps = 5000;
    /// @notice True after TBA/post-transfer owner calls `setStakingShareBps` once; cannot change again.
    bool public stakingShareBpsLocked;
    /// @notice Ticks the pool may sit from `refTick` before swaps are skipped, at zero reference age.
    /// @dev No longer bounded below by the outer band width. That floor existed because the anchor only advanced
    ///      on a successful remint, so the gate had to tolerate a full band exit; against a reference that tracks
    ///      continuously, a genuine 10% move over ten minutes leaves a gap near 650 ticks and this bound refuses
    ///      only genuinely fast movement.
    uint256 public maxSwapTickDeviation = 1200;

    /// @notice Seconds the price reference needs to earn one tick of movement. Default 2, i.e. half a tick a
    ///         second: a genuine 10% move is tracked inside twenty minutes, one block of manipulation buys a tick.
    uint256 public secondsPerRefTick = 4;
    /// @notice Ceiling on the reference's drift allowance, so a neglected feed still bounds something.
    /// @dev At the default rate this only starts binding after about 67 minutes of keeper silence, and is
    ///      therefore invisible while the feed is healthy.
    uint256 public maxRefDrift = 2000;
    /// @notice Minimum spacing between keeper-driven `refreshPriceRef` writes.
    /// @dev Shorter is safer, not just fresher: movement is capped per unit time, so a denser cadence bounds
    ///      each individual write more tightly and limits what one poisoned write can do.
    uint256 public minRefUpdateInterval = 10 minutes;

    function setProtocolFeeOn(bool on) external onlyOwner {
        protocolFeeOn = on;
    }

    function _protocolFeeBps() internal view returns (uint256) {
        return protocolFeeOn ? protocolFeeBps : 0;
    }

    /// @notice Set reserve peel bps. No cap — `> DIVISOR` peels all deployable (no LP mint).
    function setReserveBps(uint256 bps) external {
        if (!_isOperator()) revert NotOperator();
        reserveBps = bps;
    }

    /// @notice Set ASSET inventory target bps. No cap — `0` = all WETH, `> DIVISOR` = all ASSET.
    function setTargetAssetBps(uint256 bps) external {
        if (!_isOperator()) revert NotOperator();
        targetAssetBps = bps;
    }

    function setMaxSwapTickDeviation(uint256 ticks) external onlyOwner {
        maxSwapTickDeviation = ticks;
    }

    /// @notice Capped: past 10% a floor stops bounding execution in any useful way.
    function setSwapSlippageBps(uint16 bps) external onlyOwner {
        if (bps > 1_000) revert SwapSlippageBps();
        swapSlippageBps = bps;
    }

    /// @notice Zero would let the reference adopt any price instantly, which is the whole thing this prevents.
    function setSecondsPerRefTick(uint256 seconds_) external onlyOwner {
        if (seconds_ == 0) revert RefConfig();
        secondsPerRefTick = seconds_;
    }

    /// @notice Capped at the usable tick range; past that the clamp bounds nothing.
    function setMaxRefDrift(uint256 ticks) external onlyOwner {
        if (ticks > 887_272) revert RefConfig();
        maxRefDrift = ticks;
    }

    function setMinRefUpdateInterval(uint256 interval) external onlyOwner {
        minRefUpdateInterval = interval;
    }

    /// @notice One-time set of staking/feeManager split. Only after package → TBA ownership lock.
    function setStakingShareBps(uint256 bps) external onlyOwner {
        if (!_stakingShareBpsEditable() || stakingShareBpsLocked || bps > DIVISOR) revert StakingShareBps();
        stakingShareBps = bps;
        stakingShareBpsLocked = true;
    }

    /// @dev Strategy overrides: true after factory package ownership transfer (TBA).
    function _stakingShareBpsEditable() internal view virtual returns (bool) {
        return false;
    }

    function _isOperator() internal view virtual returns (bool) {
        return false;
    }

    error NotOperator();
    error StakingShareBps();
    error SwapSlippageBps();
    error RefConfig();

    function _spacing() internal view returns (int24) {
        int24 sp = tickSpacing;
        return sp > 0 ? sp : int24(160);
    }

    function _initAutoDefaults() internal {
        tickSpacing = 160;
        rangeBelowTicks = 1120;
        rangeAboveTicks = 1120;
        innerBelowTicks = 960;
        innerAboveTicks = 960;
        slippageBps = 100;
        swapSlippageBps = 100;
        minHarvestDelay = 2 hours;
        withdrawalFeeBps = 100;
        protocolFeeBps = 600;
        protocolFeeOn = true;
        reserveBps = 5000;
        targetAssetBps = 5000;
        stakingShareBps = 5000;
        stakingShareBpsLocked = false;
        maxSwapTickDeviation = 1200;
        secondsPerRefTick = 2;
        maxRefDrift = 2000;
        minRefUpdateInterval = 5 minutes;
    }

    /// @dev Apply pool spacing + band widths. Reverts if widths are not positive multiples of `spacing`.
    function _applyBandConfig(int24 spacing, BandConfig memory bands) internal {
        if (spacing <= 0) spacing = int24(160);
        tickSpacing = spacing;
        TrailingFloorLib.requireSpacedTicks(bands.rangeBelowTicks, spacing);
        TrailingFloorLib.requireSpacedTicks(bands.rangeAboveTicks, spacing);
        TrailingFloorLib.requireSpacedTicks(bands.innerBelowTicks, spacing);
        TrailingFloorLib.requireSpacedTicks(bands.innerAboveTicks, spacing);
        AutoBandLib.requireInnerWithinOuter(
            bands.rangeBelowTicks, bands.rangeAboveTicks, bands.innerBelowTicks, bands.innerAboveTicks
        );
        rangeBelowTicks = bands.rangeBelowTicks;
        rangeAboveTicks = bands.rangeAboveTicks;
        innerBelowTicks = bands.innerBelowTicks;
        innerAboveTicks = bands.innerAboveTicks;
    }

    /// @notice Set the outer mint band and the inner comfort band together.
    /// @dev One call rather than two because the four values are only meaningful relative to each other. Setting
    ///      them separately required every intermediate state to be valid as well, so widening had to be applied
    ///      outer-first and tightening inner-first or the second call reverted. Validating all four at once
    ///      removes that ordering constraint, and lets an operator move a band atomically.
    function setBandParams(
        uint256 _rangeBelowTicks,
        uint256 _rangeAboveTicks,
        uint256 _innerBelowTicks,
        uint256 _innerAboveTicks
    ) external {
        if (!_isOperator()) revert NotOperator();
        if (tickSpacing == 0) tickSpacing = _spacing();
        TrailingFloorLib.requireSpacedTicks(_rangeBelowTicks, tickSpacing);
        TrailingFloorLib.requireSpacedTicks(_rangeAboveTicks, tickSpacing);
        TrailingFloorLib.requireSpacedTicks(_innerBelowTicks, tickSpacing);
        TrailingFloorLib.requireSpacedTicks(_innerAboveTicks, tickSpacing);
        AutoBandLib.requireInnerWithinOuter(
            _rangeBelowTicks, _rangeAboveTicks, _innerBelowTicks, _innerAboveTicks
        );
        rangeBelowTicks = _rangeBelowTicks;
        rangeAboveTicks = _rangeAboveTicks;
        innerBelowTicks = _innerBelowTicks;
        innerAboveTicks = _innerAboveTicks;
    }
}
