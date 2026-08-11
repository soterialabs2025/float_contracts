// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

contract StrategyManagerV4 is Ownable {
    constructor() Ownable(msg.sender) {}

    uint256 public constant DIVISOR = 10_000;
    uint24 public poolFeePips = 10_000;
    int24 public tickSpacing = 200;
    uint256 public withdrawalFeeBps = 200;
    /// @notice Share of collected Uniswap LP fees sent to `feeManager` (1000 = 10%).
    uint256 public protocolFeeBps = 1000;
    /// @notice Share of the WETH leg of fee-only collects unwrapped to ETH (idle, not deployed to LP). LP-owned.
    uint256 public feeReserveBps = 500;
    uint16 public slippageBps = 100;
    uint256 public minHarvestDelay = 2 hours;
    /// @notice ASSET share target (bps) for NORMAL / DEFENSIVE / pre-confirmation OFFENSIVE re-mints.
    uint256 public targetAssetBps = 5000;
    /// @notice ASSET share target (bps) after `minFloorTickCount` consecutive OFFENSIVE entries.
    uint256 public offensiveAssetBps = 4000;
    /// @notice Tick distance below base (multiple of `tickSpacing`). Default 
    uint256 public rangeBelowTicks = 600;
    /// @notice Tick distance above base (multiple of `tickSpacing`). Default
    uint256 public rangeAboveTicks = 600;
    /// @notice OFFENSIVE re-mints use `offensiveAssetBps` only after this many consecutive OFFENSIVE entries.
    uint256 public minFloorTickCount = 2;
    uint256 public offensiveStaleDuration = 3 hours;
    /// @notice Floor for tightened below-range during OFFENSIVE ratchet (multiple of `tickSpacing`).
    uint256 public minRangeBelowTicks = 200;
    /// @notice Last consecutive OFFENSIVE entry that applies below-range ratchet tightening.
    uint256 public maxOffensiveRatchetCount = 4;
    /// @notice OFFENSIVE below-range ratchet multiplier: effective *= numerator / denominator each step.
    uint256 public ratchetNumerator = 2;
    uint256 public ratchetDenominator = 3;

    error InvalidBps();

    function setFeeReserveBps(uint256 bps) external onlyOwner {
        if (bps > 5_000) revert InvalidBps();
        feeReserveBps = bps;
    }

    function setMintParams(
        uint256 _targetAssetBps,
        uint256 _offensiveAssetBps,
        uint256 _rangeBelowTicks,
        uint256 _rangeAboveTicks
    ) external onlyOwner {
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
        minFloorTickCount = _minFloorTickCount;
        offensiveStaleDuration = _offensiveStaleDuration;
        minRangeBelowTicks = _minRangeBelowTicks;
        maxOffensiveRatchetCount = _maxOffensiveRatchetCount;
        ratchetNumerator = _ratchetNumerator;
        ratchetDenominator = _ratchetDenominator;
    }
}
