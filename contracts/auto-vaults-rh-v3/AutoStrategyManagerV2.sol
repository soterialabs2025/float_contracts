// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/AutoBandLib.sol";

/// @title AutoStrategyManagerV2
/// @notice Owner-settable params for AutoStrategyV2 (dual-bucket reserve + Auto bands).
contract AutoStrategyManagerV2 is Ownable {
    constructor() Ownable(msg.sender) {}

    uint256 public constant DIVISOR = 10_000;
    /// @notice ASSET share target for balance / reserve deficit pull (default 5000 = 50/50).
    uint256 public targetAssetBps = 5000;

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
    /// @notice Share of post-protocol deposit/fee capital kept idle as reserve (default 5000 = 50%).
    uint256 public reserveBps = 5000;

    /// @notice Set reserve peel bps. No cap — `> DIVISOR` peels all deployable (no LP mint).
    function setReserveBps(uint256 bps) external onlyOwner {
        reserveBps = bps;
    }

    /// @notice Set ASSET inventory target bps. No cap — `0` = all WETH, `> DIVISOR` = all ASSET.
    function setTargetAssetBps(uint256 bps) external onlyOwner {
        targetAssetBps = bps;
    }

    function _spacing() internal view returns (int24) {
        int24 sp = tickSpacing;
        return sp > 0 ? sp : int24(200);
    }

    function _initAutoDefaults() internal {
        tickSpacing = 200;
        rangeBelowTicks = 800;
        rangeAboveTicks = 800;
        innerBelowTicks = 200;
        innerAboveTicks = 200;
        slippageBps = 100;
        minHarvestDelay = 2 hours;
        withdrawalFeeBps = 50;
        protocolFeeBps = 500;
        reserveBps = 5000;
        targetAssetBps = 5000;
    }

    function setRangeParams(uint256 _rangeBelowTicks, uint256 _rangeAboveTicks) external onlyOwner {
        if (tickSpacing == 0) tickSpacing = _spacing();
        rangeBelowTicks = _rangeBelowTicks;
        rangeAboveTicks = _rangeAboveTicks;
        AutoBandLib.requireInnerWithinOuter(rangeBelowTicks, rangeAboveTicks, innerBelowTicks, innerAboveTicks);
    }

    function setInnerBandParams(uint256 _innerBelowTicks, uint256 _innerAboveTicks) external onlyOwner {
        if (tickSpacing == 0) tickSpacing = _spacing();
        AutoBandLib.requireInnerWithinOuter(rangeBelowTicks, rangeAboveTicks, _innerBelowTicks, _innerAboveTicks);
        innerBelowTicks = _innerBelowTicks;
        innerAboveTicks = _innerAboveTicks;
    }


}
