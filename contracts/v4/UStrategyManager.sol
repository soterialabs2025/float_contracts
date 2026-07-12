// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

contract UStrategyManager is Ownable {
    constructor() Ownable(msg.sender) {}
    uint256 public constant DIVISOR = 10_000;
    int24 public tickSpacing = 200;
    /// @dev Tick distances (multiples of tickSpacing). Defaults = 2 and 3 steps at spacing 200.
    uint256 internal constant DEFAULT_TARGET_ASSET_BPS = 5000;
    uint256 internal constant DEFAULT_OFFENSIVE_ASSET_BPS = 4000;
    uint256 internal constant DEFAULT_RANGE_BELOW_TICKS = 400;
    uint256 internal constant DEFAULT_RANGE_ABOVE_TICKS = 600;
    uint256 internal constant DEFAULT_MIN_FLOOR_TICK_COUNT = 1;
    uint256 internal constant DEFAULT_OFFENSIVE_STALE_DURATION = 3 hours;
    uint256 internal constant DEFAULT_MIN_RANGE_BELOW_TICKS = 200;
    uint256 internal constant DEFAULT_RATCHET_NUMERATOR = 1;
    uint256 internal constant DEFAULT_RATCHET_DENOMINATOR = 3;
    uint16 internal constant DEFAULT_SLIPPAGE_BPS = 100;
    uint256 internal constant DEFAULT_MIN_HARVEST_DELAY = 2 hours;
    uint256 public stopLoss;
    enum StratMethod { ReBalanceOnly, OffensiveOnly, DefensiveOnly, OffensiveDefensive }
    uint256 public withdrawalFeeBps;
    uint16 public slippageBps;
    uint256 public minHarvestDelay;
    uint256 public targetAssetBps;
    uint256 public offensiveAssetBps;
    uint256 public rangeBelowTicks;
    uint256 public rangeAboveTicks;
    uint256 public minFloorTickCount;
    uint256 public offensiveStaleDuration;
    uint256 public minRangeBelowTicks;
    uint256 public ratchetNumerator;
    uint256 public ratchetDenominator;
    StratMethod public stratMethod;
    error InvalidParam();
    function _validBps(uint256 v) private pure {
        if (v == 0 || v >= 10_000) revert InvalidParam();
    }
    function _validRangeTicks(uint256 v) private view {
        if (v == 0 || v >= 10_000) revert InvalidParam();
        if (v % uint256(uint24(tickSpacing)) != 0) revert InvalidParam();
    }
    function _initStrategyDefaults() internal {
        targetAssetBps = DEFAULT_TARGET_ASSET_BPS;
        offensiveAssetBps = DEFAULT_OFFENSIVE_ASSET_BPS;
        rangeBelowTicks = DEFAULT_RANGE_BELOW_TICKS;
        rangeAboveTicks = DEFAULT_RANGE_ABOVE_TICKS;
        minFloorTickCount = DEFAULT_MIN_FLOOR_TICK_COUNT;
        offensiveStaleDuration = DEFAULT_OFFENSIVE_STALE_DURATION;
        minRangeBelowTicks = DEFAULT_MIN_RANGE_BELOW_TICKS;
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
    function setMintParams(uint256 _targetAssetBps,uint256 _offensiveAssetBps,uint256 _rangeBelowTicks,uint256 _rangeAboveTicks,uint256 _stopLoss) external onlyOwner {
        _validBps(_targetAssetBps);
        _validRangeTicks(_rangeBelowTicks);
        _validRangeTicks(_rangeAboveTicks);
        _validBps(_offensiveAssetBps);
        targetAssetBps = _targetAssetBps;
        offensiveAssetBps = _offensiveAssetBps;
        rangeBelowTicks = _rangeBelowTicks;
        rangeAboveTicks = _rangeAboveTicks;
        stopLoss = _stopLoss;
    }
    function setOffensiveParams(uint256 _minFloorTickCount,uint256 _offensiveStaleDuration,uint256 _minRangeBelowTicks,uint256 _ratchetNumerator,uint256 _ratchetDenominator) external onlyOwner {
        if (_minFloorTickCount == 0) revert InvalidParam();
        _validRangeTicks(_minRangeBelowTicks);
        if (_ratchetNumerator == 0 || _ratchetDenominator == 0) revert InvalidParam();
        if (_ratchetNumerator >= _ratchetDenominator) revert InvalidParam();
        minFloorTickCount = _minFloorTickCount;
        offensiveStaleDuration = _offensiveStaleDuration;
        minRangeBelowTicks = _minRangeBelowTicks;
        ratchetNumerator = _ratchetNumerator;
        ratchetDenominator = _ratchetDenominator;
    }
}
