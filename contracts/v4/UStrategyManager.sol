// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

contract UStrategyManager is Ownable {
    constructor() Ownable(msg.sender) {}
    struct DeviationBands {
        uint256 lowerBps;
        uint256 upperBps;
        uint256 maxTokenCapBps;
    }
    uint256 public constant DIVISOR = 10_000;
    uint24 public poolFeePips = 10_000;
    int24 public tickSpacing = 200;
    int8 public startM = 12;
    int8 public offensiveM = 10;
    uint256 public withdrawalFeeBps = 0;
    uint16 public slippageBps = 100;
    uint256 public minHarvestDelay = 2 hours;
    DeviationBands public deviationBands;
    DeviationBands public offensiveBands;
    uint256 public offensiveTargetAssetBps = 4000;
    uint256 public offensiveStaleDuration = 3 hours;
    uint32 public floorSlopeNumerator = 1;
    uint32 public floorSlopeDenominator = 8;
    uint16 public minFloorDeviationBps = 50;
    uint256 public minFloorTickCount = 2;
    function setDeviationBands(
        uint256 _lowerBps,
        uint256 _upperBps,
        uint256 _maxTokenCapBps,
        int8 _startM,
        int8 _offensiveM,
        uint256 _oLowerBps,
        uint256 _oUpperBps,
        uint256 _oMaxTokenCapBps
    ) external onlyOwner {
        deviationBands = DeviationBands({lowerBps: _lowerBps, upperBps: _upperBps, maxTokenCapBps: _maxTokenCapBps});
        offensiveBands = DeviationBands({lowerBps: _oLowerBps, upperBps: _oUpperBps, maxTokenCapBps: _oMaxTokenCapBps});
        startM = _startM;
        offensiveM = _offensiveM;
    }
    function setFloorTrailingParams(uint32 _numerator, uint32 _denominator, uint16 _minDeviationBps, uint256 _minFloorTickCount_, uint256 _offensiveTargetAssetBps_, uint256 _offensiveStaleDuration_)
        external onlyOwner
    {
        require(_denominator > 0, "denom");
        floorSlopeNumerator = _numerator;
        floorSlopeDenominator = _denominator;
        minFloorDeviationBps = _minDeviationBps;
        minFloorTickCount = _minFloorTickCount_;
        offensiveTargetAssetBps = _offensiveTargetAssetBps_;
        offensiveStaleDuration = _offensiveStaleDuration_;
    }
}
