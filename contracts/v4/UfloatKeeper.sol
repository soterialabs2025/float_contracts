// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IOutOfRangeStrategyV4.sol";
import "./interfaces/IUFloatStrategyWatched.sol";
import "./interfaces/IOperatorRegistry.sol";
import "./interfaces/IUFloatKeeper.sol";

/// @title UfloatKeeper
/// @notice Keeper for standalone `UfloatStrategyV4` contracts. No Float vault or contract manager.
/// @dev    `UfloatStrategyV4.mode()`: 3 = STABLE (skip upkeep / harvest).
///         Operators on `operatorRegistry` call upkeep/harvest (wallet sharding).
///         Harvest is not throttled by upkeep `minInterval`; strategy enforces `minHarvestDelay`.
contract UFloatKeeper is IUFloatKeeper, Ownable, ReentrancyGuard {
    uint8 private constant MODE_STABLE = 3;
    uint32 public constant DEFAULT_MIN_INTERVAL = 3;

    struct WatchedStrategy {
        address stratAddr;
        uint32 minInterval;
        uint32 lastUpkeep;
        bool active;
    }

    IOperatorRegistry public immutable operatorRegistry;
    WatchedStrategy[] public watched;

    address public strategyFactory;

    error Unauthorized();
    error ZeroAddress();
    error BadId();

    event StrategyAdded(address indexed stratAddr, uint32 minInterval);
    event StrategyUpdated(address indexed stratAddr);
    event StrategyFactoryUpdated(address indexed factory);
    event UpkeepPerformed(
        uint256 indexed id,
        address indexed strat,
        address indexed keeper,
        bool didAct,
        uint8 strategyMode,
        uint256 consecutiveOffensiveCount
    );
    event HarvestPerformed(uint256 indexed id, address indexed strat, address indexed keeper);

    constructor(address operatorRegistry_) Ownable(msg.sender) {
        if (operatorRegistry_ == address(0)) revert ZeroAddress();
        operatorRegistry = IOperatorRegistry(operatorRegistry_);
    }

    modifier onlyOperator() {
        if (!operatorRegistry.isOperator(msg.sender) && msg.sender != owner()) revert Unauthorized();
        _;
    }

    modifier onlyStrategyFactory() {
        if (msg.sender != strategyFactory && msg.sender != owner()) revert Unauthorized();
        _;
    }

    /// @inheritdoc IUFloatKeeper
    function setStrategyFactory(address factory) external onlyOwner {
        strategyFactory = factory;
        emit StrategyFactoryUpdated(factory);
    }

    /// @inheritdoc IUFloatKeeper
    function addStrategy(address strat) external onlyStrategyFactory returns (uint256 id) {
        if (strat == address(0)) revert ZeroAddress();
        watched.push(WatchedStrategy({
            stratAddr: strat,
            minInterval: DEFAULT_MIN_INTERVAL,
            lastUpkeep: 0,
            active: true
        }));
        id = watched.length - 1;
        IUFloatStrategyWatched(strat).setWatched(true);
        emit StrategyAdded(strat, DEFAULT_MIN_INTERVAL);
    }

    function updateStrategy(uint256 id, bool active, uint32 minInterval) external onlyOperator {
        if (id >= watched.length) revert BadId();
        WatchedStrategy storage ws = watched[id];
        ws.active = active;
        ws.minInterval = minInterval;
        IUFloatStrategyWatched(ws.stratAddr).setWatched(active);
        emit StrategyUpdated(ws.stratAddr);
    }

    function strategiesLength() external view returns (uint256) {
        return watched.length;
    }

    function performUpkeep(uint256 id) external nonReentrant onlyOperator {
        _performUpkeep(id, msg.sender);
    }

    function performUpkeepBatch(uint256[] calldata ids) external nonReentrant onlyOperator {
        uint256 len = ids.length;
        uint256 maxId = watched.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] >= maxId) continue;
            _performUpkeep(ids[i], msg.sender);
        }
    }

    function _performUpkeep(uint256 id, address keeper) internal {
        if (id >= watched.length) revert BadId();

        WatchedStrategy storage ws = watched[id];
        address stratAddr = ws.stratAddr;

        if (!ws.active || stratAddr == address(0)) {
            emit UpkeepPerformed(id, stratAddr, keeper, false, 0, 0);
            return;
        }

        uint32 lastUpkeep = ws.lastUpkeep;
        uint32 minInterval = ws.minInterval;
        if (lastUpkeep != 0 && minInterval > 0 && uint32(block.timestamp) < lastUpkeep + minInterval) {
            return;
        }

        IOutOfRangeStrategyV4 strat = IOutOfRangeStrategyV4(stratAddr);

        if (strat.mode() == MODE_STABLE) {
            return;
        }

        bool didAct = strat.keeperCheck();
        if (didAct) {
            ws.lastUpkeep = uint32(block.timestamp);
        }
    }

    /// @param skipIncreaseLiquidity Pass `true` to collect fees only (safer on Doppler / hooked pools).
    function performHarvest(uint256 id, bool skipIncreaseLiquidity) external nonReentrant onlyOperator {
        _performHarvest(id, skipIncreaseLiquidity, msg.sender);
    }

    function performHarvestBatch(uint256[] calldata ids, bool skipIncreaseLiquidity) external nonReentrant onlyOperator {
        uint256 len = ids.length;
        uint256 maxId = watched.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] >= maxId) continue;
            _performHarvest(ids[i], skipIncreaseLiquidity, msg.sender);
        }
    }

    function _performHarvest(uint256 id, bool skipIncreaseLiquidity, address keeper) internal {
        if (id >= watched.length) revert BadId();

        WatchedStrategy storage ws = watched[id];
        address stratAddr = ws.stratAddr;
        if (!ws.active || stratAddr == address(0)) return;

        IOutOfRangeStrategyV4 strat = IOutOfRangeStrategyV4(stratAddr);
        if (strat.mode() == MODE_STABLE) return;

        strat.harvestBoolean(skipIncreaseLiquidity);
        emit HarvestPerformed(id, stratAddr, keeper);
    }
}
