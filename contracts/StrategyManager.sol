// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract StrategyManager is Ownable {
    constructor() Ownable(msg.sender) {}

    struct DeviationBands {
        uint256 lowerBps;
        uint256 upperBps;
        uint256 maxTokenCapBps;
    }
    
    uint256 public constant DIVISOR = 10000;
    uint24 public v3Fee = 10000;
    int24 public tickSpacing = 200;
    int8 public startM = 5;
    uint256 public withdrawalFeeBps = 0;
    uint16 public slippageBps = 100;
    uint16 public fallbackSlippageBps = 300;
    uint256 public minHarvestDelay = 2 hours;
    DeviationBands public deviationBands;
    uint256 public offensiveTargetAssetBps = 4500;  
    uint32 public floorSlopeNumerator = 1;
    uint32 public floorSlopeDenominator = 3;
    uint16 public minFloorDeviationBps = 200;

    event ParamUpdated(bytes32 indexed param, uint256 val1, uint256 val2);

    function setDeviationBands(uint256 _lowerBps, uint256 _upperBps, uint256 _maxTokenCapBps, int8 _startM) external onlyOwner {
        deviationBands = DeviationBands({lowerBps: _lowerBps, upperBps: _upperBps, maxTokenCapBps: _maxTokenCapBps});
        startM = _startM;
        emit ParamUpdated(bytes32("deviationBands"), _maxTokenCapBps, _lowerBps);
        emit ParamUpdated(bytes32("startM"), uint256(int256(_startM)), 0);
    }
    function setOffensiveTargetAssetBps(uint256 _offensiveTargetAssetBps) external onlyOwner {
        require(_offensiveTargetAssetBps <= DIVISOR, ">100%");
        offensiveTargetAssetBps = _offensiveTargetAssetBps;
        emit ParamUpdated(bytes32("offensiveTargetBps"), _offensiveTargetAssetBps, 0);
    }
    function setFloorTrailingParams(uint32 _numerator, uint32 _denominator, uint16 _minDeviationBps) external onlyOwner {
        require(_denominator > 0, "denom");
        floorSlopeNumerator = _numerator;
        floorSlopeDenominator = _denominator;
        minFloorDeviationBps = _minDeviationBps;
        emit ParamUpdated(bytes32("floorTrail"), uint256(_numerator), uint256(_denominator));
    }

}
