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
    /// @notice Asymmetric LP range: bps below current tick 
    uint256 public rangeBelowBps = 600;
    /// @notice Asymmetric LP range: bps above current tick
    uint256 public rangeAboveBps = 800;
    /// @notice OFFENSIVE re-mints use `offensiveAssetBps` only after this many consecutive OFFENSIVE entries.
    uint256 public minFloorTickCount = 2;
    uint256 public offensiveStaleDuration = 3 hours;
    /// @notice Floor for tightened below-range during OFFENSIVE ratchet 
    uint256 public minRangeBelowBps = 200;
    /// @notice Last consecutive OFFENSIVE entry that applies below-range ratchet tightening.
    uint256 public maxOffensiveRatchetCount = 4;
    /// @notice OFFENSIVE below-range ratchet multiplier: effective *= numerator / denominator each step (default 2/3).
    uint256 public ratchetNumerator = 1;
    uint256 public ratchetDenominator = 3;

    error InvalidBps();
    error InvalidCount();
    error InvalidRatchetCap();
    error InvalidRatchet();
    error RatchetMustTighten();

    function setMintParams(
        uint256 _targetAssetBps,
        uint256 _offensiveAssetBps,
        uint256 _rangeBelowBps,
        uint256 _rangeAboveBps
    ) external onlyOwner {
        if (_targetAssetBps == 0 || _targetAssetBps >= 10_000) revert InvalidBps();
        if (_offensiveAssetBps == 0 || _offensiveAssetBps >= 10_000) revert InvalidBps();
        if (_rangeBelowBps == 0 || _rangeBelowBps >= 10_000) revert InvalidBps();
        if (_rangeAboveBps == 0 || _rangeAboveBps >= 10_000) revert InvalidBps();
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
