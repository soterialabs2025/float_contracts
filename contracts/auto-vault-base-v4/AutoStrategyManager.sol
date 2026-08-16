// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/AutoBandLib.sol";
import "../v4/libraries/TrailingFloorLib.sol";

/// @title AutoStrategyManager
/// @notice Owner-settable params for AutoStrategy (no StratMethod / no offensive ratchet).
contract AutoStrategyManager is Ownable {
    constructor() Ownable(msg.sender) {}

    uint256 public constant DIVISOR = 10_000;
    /// @dev Fixed 50/50 inventory target — not owner-settable.
    uint256 public constant TARGET_ASSET_BPS = 5000;

    int24 public tickSpacing = 200;
    uint256 public rangeBelowTicks = 800;
    uint256 public rangeAboveTicks = 800;
    uint256 public innerBelowTicks = 200;
    uint256 public innerAboveTicks = 200;

    uint16 public slippageBps = 100;
    uint256 public minHarvestDelay = 2 hours;
    uint256 public withdrawalFeeBps = 50;
    /// @notice Share of fee-only collects sent to `feeManager` (default 500 = 5%).
    uint256 public protocolFeeBps = 500;

    error InvalidParam();

    function _spacing() internal view returns (int24) {
        int24 sp = tickSpacing;
        return sp > 0 ? sp : int24(200);
    }

    function _validRangeTicks(uint256 v) internal view {
        if (v == 0 || v >= 10_000) revert InvalidParam();
        if (v % uint256(uint24(_spacing())) != 0) revert InvalidParam();
    }

    function _initAutoDefaults() internal {
        tickSpacing = 200;
        rangeBelowTicks = 600;
        rangeAboveTicks = 600;
        innerBelowTicks = 200;
        innerAboveTicks = 200;
        slippageBps = 100;
        minHarvestDelay = 2 hours;
        withdrawalFeeBps = 50;
        protocolFeeBps = 500;
    }

    function setRangeParams(uint256 _rangeBelowTicks, uint256 _rangeAboveTicks) external onlyOwner {
        _validRangeTicks(_rangeBelowTicks);
        _validRangeTicks(_rangeAboveTicks);
        if (tickSpacing == 0) tickSpacing = _spacing();
        rangeBelowTicks = _rangeBelowTicks;
        rangeAboveTicks = _rangeAboveTicks;
        AutoBandLib.requireInnerWithinOuter(rangeBelowTicks, rangeAboveTicks, innerBelowTicks, innerAboveTicks);
    }

    function setInnerBandParams(uint256 _innerBelowTicks, uint256 _innerAboveTicks) external onlyOwner {
        _validRangeTicks(_innerBelowTicks);
        _validRangeTicks(_innerAboveTicks);
        if (tickSpacing == 0) tickSpacing = _spacing();
        AutoBandLib.requireInnerWithinOuter(rangeBelowTicks, rangeAboveTicks, _innerBelowTicks, _innerAboveTicks);
        innerBelowTicks = _innerBelowTicks;
        innerAboveTicks = _innerAboveTicks;
    }

    function setProtocolFeeBps(uint256 bps) external onlyOwner {
        if (bps > 2_000) revert InvalidParam(); // hard cap 20%
        protocolFeeBps = bps;
    }

    function setWithdrawalFeeBps(uint256 bps) external onlyOwner {
        if (bps >= DIVISOR) revert InvalidParam();
        withdrawalFeeBps = bps;
    }

    function setSlippageBps(uint16 bps) external onlyOwner {
        if (bps > 1_000) revert InvalidParam();
        slippageBps = bps;
    }

    function setMinHarvestDelay(uint256 delay) external onlyOwner {
        minHarvestDelay = delay;
    }
}
