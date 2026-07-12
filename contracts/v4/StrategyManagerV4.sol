// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

contract StrategyManagerV4 is Ownable {
    constructor() Ownable(msg.sender) {}

    uint256 public constant DIVISOR = 10_000;
    uint24 public poolFeePips = 10_000;
    int24 public tickSpacing = 200;
    uint256 public withdrawalFeeBps = 0;
    uint16 public slippageBps = 100;
    uint256 public minHarvestDelay = 2 hours;
    /// @notice ASSET share target (bps) for NORMAL / DEFENSIVE / pre-confirmation OFFENSIVE re-mints.
    uint256 public targetAssetBps = 5000;
    /// @notice ASSET share target (bps) after `minFloorTickCount` consecutive OFFENSIVE entries.
    uint256 public offensiveAssetBps = 4000;
    /// @notice Tick distance below base (multiple of `tickSpacing`). Default 400 = 2×200 ≈ one Uni slider step pair.
    uint256 public rangeBelowTicks = 400;
    /// @notice Tick distance above base (multiple of `tickSpacing`). Default 600 = 3×200.
    uint256 public rangeAboveTicks = 600;
    /// @notice OFFENSIVE re-mints use `offensiveAssetBps` only after this many consecutive OFFENSIVE entries.
    uint256 public minFloorTickCount = 2;
    uint256 public offensiveStaleDuration = 3 hours;
    /// @notice Floor for tightened below-range during OFFENSIVE ratchet (multiple of `tickSpacing`).
    uint256 public minRangeBelowTicks = 200;
    /// @notice Last consecutive OFFENSIVE entry that applies below-range ratchet tightening.
    uint256 public maxOffensiveRatchetCount = 4;
    /// @notice OFFENSIVE below-range ratchet multiplier: effective *= numerator / denominator each step.
    uint256 public ratchetNumerator = 1;
    uint256 public ratchetDenominator = 3;

    error InvalidBps();
    error InvalidRangeTicks();
    error InvalidCount();
    error InvalidRatchetCap();
    error InvalidRatchet();
    error RatchetMustTighten();

    function setMintParams(
        uint256 _targetAssetBps,
        uint256 _offensiveAssetBps,
        uint256 _rangeBelowTicks,
        uint256 _rangeAboveTicks
    ) external onlyOwner {
        if (_targetAssetBps == 0 || _targetAssetBps >= 10_000) revert InvalidBps();
        if (_offensiveAssetBps == 0 || _offensiveAssetBps >= 10_000) revert InvalidBps();
        if (_rangeBelowTicks == 0 || _rangeBelowTicks >= 10_000) revert InvalidRangeTicks();
        if (_rangeAboveTicks == 0 || _rangeAboveTicks >= 10_000) revert InvalidRangeTicks();
        if (_rangeBelowTicks % uint256(uint24(tickSpacing)) != 0) revert InvalidRangeTicks();
        if (_rangeAboveTicks % uint256(uint24(tickSpacing)) != 0) revert InvalidRangeTicks();
        targetAssetBps = _targetAssetBps;
        offensiveAssetBps = _offensiveAssetBps;
        rangeBelowTicks = _rangeBelowTicks;
        rangeAboveTicks = _rangeAboveTicks;
    }

    function setOffensiveParams(
        uint256 _minFloorTickCount,
        uint256 _offensiveStaleDuration,
        uint256 _minRangeBelowTicks,
        uint256 _maxOffensiveRatchetCount,
        uint256 _ratchetNumerator,
        uint256 _ratchetDenominator
    ) external onlyOwner {
        if (_minFloorTickCount == 0) revert InvalidCount();
        if (_minRangeBelowTicks == 0 || _minRangeBelowTicks >= 10_000) revert InvalidRangeTicks();
        if (_minRangeBelowTicks % uint256(uint24(tickSpacing)) != 0) revert InvalidRangeTicks();
        if (_maxOffensiveRatchetCount < _minFloorTickCount) revert InvalidRatchetCap();
        if (_ratchetNumerator == 0 || _ratchetDenominator == 0) revert InvalidRatchet();
        if (_ratchetNumerator >= _ratchetDenominator) revert RatchetMustTighten();
        minFloorTickCount = _minFloorTickCount;
        offensiveStaleDuration = _offensiveStaleDuration;
        minRangeBelowTicks = _minRangeBelowTicks;
        maxOffensiveRatchetCount = _maxOffensiveRatchetCount;
        ratchetNumerator = _ratchetNumerator;
        ratchetDenominator = _ratchetDenominator;
    }
}
