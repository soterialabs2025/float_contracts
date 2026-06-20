// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Tunable params for standalone UFloat strategies (OOR tick model — no deviation bands).
/// @dev Clones start with zeroed storage — call `_initStrategyDefaults()` once at bootstrap (field initializers do not apply).
contract UStrategyManager is Ownable {
    constructor() Ownable(msg.sender) {}

    uint256 public constant DIVISOR = 10_000;

    uint256 internal constant DEFAULT_TARGET_ASSET_BPS = 5000;
    uint256 internal constant DEFAULT_OFFENSIVE_ASSET_BPS = 4000;
    uint256 internal constant DEFAULT_RANGE_BELOW_BPS = 800;
    uint256 internal constant DEFAULT_RANGE_ABOVE_BPS = 1000;
    uint256 internal constant DEFAULT_MIN_FLOOR_TICK_COUNT = 1;
    uint256 internal constant DEFAULT_OFFENSIVE_STALE_DURATION = 3 hours;
    uint256 internal constant DEFAULT_MIN_RANGE_BELOW_BPS = 200;
    uint256 internal constant DEFAULT_MAX_OFFENSIVE_RATCHET_COUNT = 4;
    uint256 internal constant DEFAULT_RATCHET_NUMERATOR = 1;
    uint256 internal constant DEFAULT_RATCHET_DENOMINATOR = 3;
    uint16 internal constant DEFAULT_SLIPPAGE_BPS = 100;
    uint256 internal constant DEFAULT_MIN_HARVEST_DELAY = 2 hours;

    enum StratMethod { ReBalanceOnly, OffensiveOnly, DefensiveOnly, OffensiveDefensive }

    uint24 public poolFeePips;
    int24 public tickSpacing;
    uint256 public withdrawalFeeBps;
    uint16 public slippageBps;
    uint256 public minHarvestDelay;
    /// @notice ASSET share target (bps of total value) before every mint / rebalance swap in NORMAL / DEFENSIVE.
    uint256 public targetAssetBps;
    /// @notice ASSET share target (bps) when re-minting in OFFENSIVE mode (OOR all-WETH side).
    uint256 public offensiveAssetBps;
    /// @notice Asymmetric LP range: bps below current tick (1000 = 10%).
    uint256 public rangeBelowBps;
    /// @notice Asymmetric LP range: bps above current tick (2000 = 20%).
    uint256 public rangeAboveBps;
    /// @notice OFFENSIVE below-range ratchet and `offensiveAssetBps` apply after this many consecutive OFFENSIVE entries.
    uint256 public minFloorTickCount;
    /// @notice Max time in OFFENSIVE before exiting to NORMAL and re-minting at `targetAssetBps` range.
    uint256 public offensiveStaleDuration;
    /// @notice Floor for tightened below-range during OFFENSIVE ratchet (200 = 2%).
    uint256 public minRangeBelowBps;
    /// @notice Last consecutive OFFENSIVE entry that applies below-range ratchet tightening.
    uint256 public maxOffensiveRatchetCount;
    /// @notice OFFENSIVE below-range ratchet multiplier: effective *= numerator / denominator each step (default 1/3).
    uint256 public ratchetNumerator;
    uint256 public ratchetDenominator;
    /// @notice OOR / idle upkeep behavior. Default `ReBalanceOnly` remints at `targetAssetBps` without mode changes.
    StratMethod public stratMethod;

    error InvalidBps();
    error InvalidCount();
    error InvalidRatchetCap();
    error InvalidRatchet();
    error RatchetMustTighten();

    /// @dev Required for EIP-1167 clones; implementation field initializers are not copied to clone storage.
    function _initStrategyDefaults() internal {
        targetAssetBps = DEFAULT_TARGET_ASSET_BPS;
        offensiveAssetBps = DEFAULT_OFFENSIVE_ASSET_BPS;
        rangeBelowBps = DEFAULT_RANGE_BELOW_BPS;
        rangeAboveBps = DEFAULT_RANGE_ABOVE_BPS;
        minFloorTickCount = DEFAULT_MIN_FLOOR_TICK_COUNT;
        offensiveStaleDuration = DEFAULT_OFFENSIVE_STALE_DURATION;
        minRangeBelowBps = DEFAULT_MIN_RANGE_BELOW_BPS;
        maxOffensiveRatchetCount = DEFAULT_MAX_OFFENSIVE_RATCHET_COUNT;
        ratchetNumerator = DEFAULT_RATCHET_NUMERATOR;
        ratchetDenominator = DEFAULT_RATCHET_DENOMINATOR;
        slippageBps = DEFAULT_SLIPPAGE_BPS;
        minHarvestDelay = DEFAULT_MIN_HARVEST_DELAY;
        withdrawalFeeBps = 0;
        stratMethod = StratMethod.ReBalanceOnly;
    }

    function setStratMethod(StratMethod method) external onlyOwner {
        stratMethod = method;
    }

    function setMintParams(
        uint256 _targetAssetBps,
        uint256 _offensiveAssetBps,
        uint256 _rangeBelowBps,
        uint256 _rangeAboveBps
    ) external onlyOwner {
        if (_targetAssetBps == 0 || _targetAssetBps >= 10_000) revert InvalidBps();
        if (_rangeBelowBps == 0 || _rangeBelowBps >= 10_000) revert InvalidBps();
        if (_rangeAboveBps == 0 || _rangeAboveBps >= 10_000) revert InvalidBps();
        if (_offensiveAssetBps == 0 || _offensiveAssetBps >= 10_000) revert InvalidBps();
        targetAssetBps = _targetAssetBps;
        offensiveAssetBps = _offensiveAssetBps;
        rangeBelowBps = _rangeBelowBps;
        rangeAboveBps = _rangeAboveBps;
    }

    function setOffensiveParams(
        uint256 _minFloorTickCount,
        uint256 _offensiveStaleDuration,
        uint256 _minRangeBelowBps,
        uint256 _maxOffensiveRatchetCount,
        uint256 _ratchetNumerator,
        uint256 _ratchetDenominator
    ) external onlyOwner {
        if (_minFloorTickCount == 0) revert InvalidCount();
        if (_minRangeBelowBps == 0 || _minRangeBelowBps >= 10_000) revert InvalidBps();
        if (_maxOffensiveRatchetCount < _minFloorTickCount) revert InvalidRatchetCap();
        if (_ratchetNumerator == 0 || _ratchetDenominator == 0) revert InvalidRatchet();
        if (_ratchetNumerator >= _ratchetDenominator) revert RatchetMustTighten();
        minFloorTickCount = _minFloorTickCount;
        offensiveStaleDuration = _offensiveStaleDuration;
        minRangeBelowBps = _minRangeBelowBps;
        maxOffensiveRatchetCount = _maxOffensiveRatchetCount;
        ratchetNumerator = _ratchetNumerator;
        ratchetDenominator = _ratchetDenominator;
    }
}
