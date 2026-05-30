// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IOutOfRangeStrategyV4.sol";
import "./interfaces/IUFloatKeeper.sol";

/// @title UfloatKeeper
/// @notice Keeper for standalone `UfloatStrategyV4` contracts. No Float vault or contract manager.
/// @dev `UfloatStrategyV4.mode()`: 3 = STABLE (skip upkeep / harvest).
contract UFloatKeeper is IUFloatKeeper, Ownable, ReentrancyGuard { 
    uint8 private constant MODE_STABLE = 3;
    uint32 public constant DEFAULT_MIN_INTERVAL = 3;

    struct WatchedStrategy {
        address stratAddr;
        uint32 minInterval;
        uint32 lastAction;
        bool active;
    }

    WatchedStrategy[] public watched;

    address public demeterAddr;
    address public strategyFactory;

    error Unauthorized();
    error ZeroAddress();

    event StrategyAdded(address indexed stratAddr, uint32 minInterval);
    event StrategyUpdated(address indexed stratAddr);
    event StrategyFactoryUpdated(address indexed factory);
    event UpkeepPerformed(
        uint256 indexed id,
        address indexed strat,
        address indexed keeper,
        bool didAct,
        uint8 strategyMode,
        uint256 consecutiveOffensiveCount,
        uint256 defensiveEnteredAt
    );

    constructor(address _demeterAddr) Ownable(msg.sender) {
        if (_demeterAddr == address(0)) revert ZeroAddress();
        demeterAddr = _demeterAddr;
    }

    modifier onlyAuthorized() {
        address s = _msgSender();
        if (s != demeterAddr && s != owner() && s != strategyFactory) revert Unauthorized();
        _;
    }

    /// @inheritdoc IUFloatKeeper
    function setStrategyFactory(address factory) external onlyOwner {
        strategyFactory = factory;
        emit StrategyFactoryUpdated(factory);
    }

    /// @inheritdoc IUFloatKeeper
    function addStrategy(address strat) external onlyAuthorized returns (uint256 id) {
        if (strat == address(0)) revert ZeroAddress();
        watched.push(WatchedStrategy({
            stratAddr: strat,
            minInterval: DEFAULT_MIN_INTERVAL,
            lastAction: 0,
            active: true
        }));
        id = watched.length - 1;
        emit StrategyAdded(strat, DEFAULT_MIN_INTERVAL);
    }

    function updateStrategy(uint256 id, bool active, uint32 minInterval) external onlyAuthorized {
        require(id < watched.length, "bad id");
        WatchedStrategy storage ws = watched[id];
        ws.active = active;
        ws.minInterval = minInterval;
        emit StrategyUpdated(ws.stratAddr);
    }

    function strategiesLength() external view returns (uint256) {
        return watched.length;
    }

    function performUpkeep(uint256 id) external nonReentrant {
        require(id < watched.length, "bad id");

        WatchedStrategy storage ws = watched[id];
        address stratAddr = ws.stratAddr;

        if (!ws.active || stratAddr == address(0)) {
            emit UpkeepPerformed(id, stratAddr, msg.sender, false, 0, 0, 0);
            return;
        }

        uint32 lastAction = ws.lastAction;
        uint32 minInterval = ws.minInterval;
        if (lastAction != 0 && minInterval > 0 && uint32(block.timestamp) < lastAction + minInterval) {
            IOutOfRangeStrategyV4 s0 = IOutOfRangeStrategyV4(stratAddr);
            emit UpkeepPerformed(
                id, stratAddr, msg.sender, false, s0.mode(), s0.consecutiveOffensiveCount(), s0.defensiveEnteredAt()
            );
            return;
        }

        IOutOfRangeStrategyV4 strat = IOutOfRangeStrategyV4(stratAddr);

        uint8 strategyMode = strat.mode();
        if (strategyMode == MODE_STABLE) {
            emit UpkeepPerformed(
                id, stratAddr, msg.sender, false, strategyMode, strat.consecutiveOffensiveCount(), strat.defensiveEnteredAt()
            );
            return;
        }

        if (!strat.keeperCheck()) {
            emit UpkeepPerformed(
                id, stratAddr, msg.sender, false, strat.mode(), strat.consecutiveOffensiveCount(), strat.defensiveEnteredAt()
            );
            return;
        }

        try strat.harvestBoolean(true) returns (uint256) {} catch {}

        ws.lastAction = uint32(block.timestamp);
        emit UpkeepPerformed(
            id, stratAddr, msg.sender, true, strat.mode(), strat.consecutiveOffensiveCount(), strat.defensiveEnteredAt()
        );
    }

    function performUpkeepBatch(uint256[] calldata ids) external {
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; i++) {
            try this.performUpkeep(ids[i]) {} catch {}
        }
    }

    function performHarvest(uint256 id, bool skipIncreaseLiquidity) external nonReentrant {
        require(id < watched.length, "bad id");

        WatchedStrategy storage ws = watched[id];
        address stratAddr = ws.stratAddr;

        if (!ws.active || stratAddr == address(0)) {
            emit UpkeepPerformed(id, stratAddr, msg.sender, false, 0, 0, 0);
            return;
        }

        uint32 lastAction = ws.lastAction;
        uint32 minInterval = ws.minInterval;
        if (lastAction != 0 && minInterval > 0 && uint32(block.timestamp) < lastAction + minInterval) {
            IOutOfRangeStrategyV4 s0 = IOutOfRangeStrategyV4(stratAddr);
            emit UpkeepPerformed(
                id, stratAddr, msg.sender, false, s0.mode(), s0.consecutiveOffensiveCount(), s0.defensiveEnteredAt()
            );
            return;
        }

        IOutOfRangeStrategyV4 strat = IOutOfRangeStrategyV4(stratAddr);

        uint8 strategyMode = strat.mode();
        if (strategyMode == MODE_STABLE) {
            emit UpkeepPerformed(
                id, stratAddr, msg.sender, false, strategyMode, strat.consecutiveOffensiveCount(), strat.defensiveEnteredAt()
            );
            return;
        }

        try strat.harvestBoolean(skipIncreaseLiquidity) returns (uint256) {} catch {
            emit UpkeepPerformed(
                id, stratAddr, msg.sender, false, strat.mode(), strat.consecutiveOffensiveCount(), strat.defensiveEnteredAt()
            );
            return;
        }

        ws.lastAction = uint32(block.timestamp);
        emit UpkeepPerformed(
            id, stratAddr, msg.sender, true, strat.mode(), strat.consecutiveOffensiveCount(), strat.defensiveEnteredAt()
        );
    }
}
