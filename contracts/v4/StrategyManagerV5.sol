// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title StrategyManagerV5
/// @notice Params for FloatStrategyV5 dual-bucket reserve (both fee legs / deposits).
contract StrategyManagerV5 is Ownable {
    constructor() Ownable(msg.sender) {}

    uint256 public constant DIVISOR = 10_000;
    uint24 public poolFeePips = 10_000;
    int24 public tickSpacing = 200;
    uint256 public withdrawalFeeBps = 200;
    /// @notice Share of collected Uniswap LP fees sent to `feeManager` (1000 = 10%).
    uint256 public protocolFeeBps = 1000;
    /// @notice Share of post-protocol deposit/fee capital kept idle as reserve (both legs). Default 4000 = 40%.
    uint256 public reserveBps = 4000;
    uint16 public slippageBps = 100;
    uint256 public minHarvestDelay = 2 hours;
    uint256 public targetAssetBps = 5000;
    uint256 public offensiveAssetBps = 4000;
    uint256 public rangeBelowTicks = 600;
    uint256 public rangeAboveTicks = 600;
    uint256 public minFloorTickCount = 2;
    uint256 public offensiveStaleDuration = 3 hours;
    uint256 public minRangeBelowTicks = 200;
    uint256 public maxOffensiveRatchetCount = 4;
    uint256 public ratchetNumerator = 2;
    uint256 public ratchetDenominator = 3;

    error InvalidBps();

    function setReserveBps(uint256 bps) external onlyOwner {
        if (bps > 5_000) revert InvalidBps();
        reserveBps = bps;
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
