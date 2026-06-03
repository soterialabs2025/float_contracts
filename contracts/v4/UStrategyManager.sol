// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Tunable params for standalone UFloat strategies (OOR tick model — no deviation bands).
contract UStrategyManager is Ownable {
    constructor() Ownable(msg.sender) {}

    uint256 public constant DIVISOR = 10_000;
    uint24 public poolFeePips = 10_000;
    int24 public tickSpacing = 200;
    uint256 public withdrawalFeeBps = 0;
    uint16 public slippageBps = 100;
    uint256 public minHarvestDelay = 2 hours;
    /// @notice ASSET share target (bps of total value) before every mint / rebalance swap in NORMAL / DEFENSIVE.
    uint256 public targetAssetBps = 5000;
    /// @notice ASSET share target (bps) when re-minting in OFFENSIVE mode (OOR all-WETH side).
    uint256 public offensiveAssetBps = 4000;
    /// @notice Asymmetric LP range: bps below current tick (1000 = 10%).
    uint256 public rangeBelowBps = 1000;
    /// @notice Asymmetric LP range: bps above current tick (2000 = 20%).
    uint256 public rangeAboveBps = 2000;
    /// @notice OFFENSIVE below-range ratchet and `offensiveAssetBps` apply after this many consecutive OFFENSIVE entries.
    uint256 public minFloorTickCount = 2;
    /// @notice Max time in OFFENSIVE before exiting to NORMAL and re-minting at `targetAssetBps` range.
    uint256 public offensiveStaleDuration = 3 hours;
    /// @notice Floor for tightened below-range during OFFENSIVE ratchet (200 = 2%).
    uint256 public minRangeBelowBps = 200;
    /// @notice Last consecutive OFFENSIVE entry that applies below-range ratchet tightening.
    uint256 public maxOffensiveRatchetCount = 4;
    /// @notice OFFENSIVE below-range ratchet multiplier: effective *= numerator / denominator each step (default 1/3).
    uint256 public ratchetNumerator = 1;
    uint256 public ratchetDenominator = 3;

    function setMintParams(
        uint256 _targetAssetBps,
        uint256 _offensiveAssetBps,
        uint256 _rangeBelowBps,
        uint256 _rangeAboveBps
    ) external onlyOwner {
        require(_targetAssetBps > 0 && _targetAssetBps < 10_000, "!bps");
        require(_rangeBelowBps > 0 && _rangeBelowBps < 10_000, "!bps");
        require(_rangeAboveBps > 0 && _rangeAboveBps < 10_000, "!bps");
        require(_offensiveAssetBps > 0 && _offensiveAssetBps < 10_000, "!bps");
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
        require(_minFloorTickCount > 0, "!count");
        require(_minRangeBelowBps > 0 && _minRangeBelowBps < 10_000, "!min bps");
        require(_maxOffensiveRatchetCount >= _minFloorTickCount, "!cap");
        require(_ratchetNumerator > 0 && _ratchetDenominator > 0, "!ratchet");
        require(_ratchetNumerator < _ratchetDenominator, "ratchet must tighten");
        minFloorTickCount = _minFloorTickCount;
        offensiveStaleDuration = _offensiveStaleDuration;
        minRangeBelowBps = _minRangeBelowBps;
        maxOffensiveRatchetCount = _maxOffensiveRatchetCount;
        ratchetNumerator = _ratchetNumerator;
        ratchetDenominator = _ratchetDenominator;
    }
}
