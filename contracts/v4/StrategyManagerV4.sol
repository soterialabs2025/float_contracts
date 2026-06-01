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
    /// @notice Asymmetric LP range: bps below current tick (1000 = 10%).
    uint256 public rangeBelowBps = 1000;
    /// @notice Asymmetric LP range: bps above current tick (2000 = 20%).
    uint256 public rangeAboveBps = 2000;
    /// @notice OFFENSIVE re-mints use `offensiveAssetBps` only after this many consecutive OFFENSIVE entries.
    uint256 public minFloorTickCount = 2;
    uint256 public offensiveStaleDuration = 3 hours;

    function setMintParams(
        uint256 _targetAssetBps,
        uint256 _offensiveAssetBps,
        uint256 _rangeBelowBps,
        uint256 _rangeAboveBps
    ) external onlyOwner {
        require(_targetAssetBps > 0 && _targetAssetBps < 10_000, "bad target bps");
        require(_offensiveAssetBps > 0 && _offensiveAssetBps < 10_000, "bad offensive bps");
        require(_rangeBelowBps > 0 && _rangeBelowBps < 10_000, "bad below bps");
        require(_rangeAboveBps > 0 && _rangeAboveBps < 10_000, "bad above bps");
        targetAssetBps = _targetAssetBps;
        offensiveAssetBps = _offensiveAssetBps;
        rangeBelowBps = _rangeBelowBps;
        rangeAboveBps = _rangeAboveBps;
    }

    function setOffensiveParams(uint256 _minFloorTickCount, uint256 _offensiveStaleDuration) external onlyOwner {
        require(_minFloorTickCount > 0, "bad floor count");
        minFloorTickCount = _minFloorTickCount;
        offensiveStaleDuration = _offensiveStaleDuration;
    }
}
