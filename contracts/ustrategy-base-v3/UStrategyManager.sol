// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

contract UStrategyManager is Ownable {
    constructor() Ownable(msg.sender) {}
    uint256 public constant DIVISOR = 10_000;
    uint256 public constant RATCHET_NUMERATOR = 2;
    uint256 public constant RATCHET_DENOMINATOR = 3;
    int24 public tickSpacing = 200;
    uint256 internal constant DEFAULT_TARGET_ASSET_BPS = 5000;
    uint256 internal constant DEFAULT_OFFENSIVE_ASSET_BPS = 4500;
    uint256 internal constant DEFAULT_RANGE_BELOW_TICKS = 600;
    uint256 internal constant DEFAULT_RANGE_ABOVE_TICKS = 600;
    uint256 internal constant DEFAULT_MIN_FLOOR_TICK_COUNT = 1;
    uint256 internal constant DEFAULT_OFFENSIVE_STALE_DURATION = 3 hours;
    uint256 internal constant DEFAULT_MIN_RANGE_BELOW_TICKS = 200;
    uint16 internal constant DEFAULT_SLIPPAGE_BPS = 100;
    uint256 internal constant DEFAULT_MIN_HARVEST_DELAY = 2 hours;
    uint256 internal constant DEFAULT_WITHDRAWAL_FEE_BPS = 100;
    uint256 internal constant DEFAULT_PROTOCOL_FEE_BPS = 1000;
    uint256 public constant MAX_FEE_RESERVE_BPS = 9000;
    uint256 internal constant DEFAULT_FEE_RESERVE_BPS = 0;
    uint256 public protocolFeeBps;
    uint256 public feeReserveBps;
    address public reserveAddress;
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
    StratMethod public stratMethod;
    error InvalidParam();
    function _spacing() private view returns (int24) {
        int24 sp = tickSpacing;
        return sp > 0 ? sp : int24(200);
    }
    function _validBps(uint256 v) private pure {
        if (v == 0 || v >= 10_000) revert InvalidParam();
    }
    function _validRangeTicks(uint256 v) private view {
        if (v == 0 || v >= 10_000) revert InvalidParam();
        if (v % uint256(uint24(_spacing())) != 0) revert InvalidParam();
    }
    function _initStrategyDefaults() internal {
        tickSpacing = 200;
        targetAssetBps = DEFAULT_TARGET_ASSET_BPS;
        offensiveAssetBps = DEFAULT_OFFENSIVE_ASSET_BPS;
        rangeBelowTicks = DEFAULT_RANGE_BELOW_TICKS;
        rangeAboveTicks = DEFAULT_RANGE_ABOVE_TICKS;
        minFloorTickCount = DEFAULT_MIN_FLOOR_TICK_COUNT;
        offensiveStaleDuration = DEFAULT_OFFENSIVE_STALE_DURATION;
        minRangeBelowTicks = DEFAULT_MIN_RANGE_BELOW_TICKS;
        slippageBps = DEFAULT_SLIPPAGE_BPS;
        minHarvestDelay = DEFAULT_MIN_HARVEST_DELAY;
        withdrawalFeeBps = DEFAULT_WITHDRAWAL_FEE_BPS;
        protocolFeeBps = DEFAULT_PROTOCOL_FEE_BPS;
        feeReserveBps = DEFAULT_FEE_RESERVE_BPS;
        stratMethod = StratMethod.ReBalanceOnly;
    }
    function setStratMethod(StratMethod method) external onlyOwner {
        stratMethod = method;
    }
    function setMintParams(
        uint256 _targetAssetBps,
        uint256 _rangeBelowTicks,
        uint256 _rangeAboveTicks,
        uint256 _stopLoss,
        uint256 _feeReserveBps,
        address _reserveAddress
    ) external onlyOwner {
        _validBps(_targetAssetBps);
        _validRangeTicks(_rangeBelowTicks);
        _validRangeTicks(_rangeAboveTicks);
        if (_feeReserveBps > MAX_FEE_RESERVE_BPS) revert InvalidParam();
        if (_reserveAddress == address(0)) revert InvalidParam();
        if (tickSpacing == 0) tickSpacing = _spacing();
        targetAssetBps = _targetAssetBps;
        rangeBelowTicks = _rangeBelowTicks;
        rangeAboveTicks = _rangeAboveTicks;
        stopLoss = _stopLoss;
        feeReserveBps = _feeReserveBps;
        reserveAddress = _reserveAddress;
    }
    function setOffensiveParams(uint256 _minFloorTickCount, uint256 _offensiveStaleDuration,uint256 _offensiveAssetBps, uint256 _minRangeBelowTicks) external onlyOwner {
        if (_minFloorTickCount == 0) revert InvalidParam();
        _validRangeTicks(_minRangeBelowTicks);
        _validBps(_offensiveAssetBps);
        if (tickSpacing == 0) tickSpacing = _spacing();
        offensiveAssetBps = _offensiveAssetBps;
        minFloorTickCount = _minFloorTickCount;
        offensiveStaleDuration = _offensiveStaleDuration;
        minRangeBelowTicks = _minRangeBelowTicks;
    }
}
