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
}
