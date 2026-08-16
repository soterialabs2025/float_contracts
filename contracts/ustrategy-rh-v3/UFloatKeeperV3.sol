// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IOutOfRangeStrategyV3.sol";
import "./interfaces/IUFloatStrategyWatched.sol";
import "./interfaces/IUFloatStrategyV3.sol";
import "./interfaces/IOperatorRegistry.sol";
import "./interfaces/IUFloatKeeper.sol";

/// @title UFloatKeeperV3
/// @notice Keeper for standalone UFloatStrategyV3. No vault or contract manager.
contract UFloatKeeperV3 is IUFloatKeeper, Ownable, ReentrancyGuard {
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

    mapping(address => PoolValueSnapshot[]) private _poolValueSnapshots;

    error Unauthorized();
    error ZeroAddress();
    error BadId();

    event StrategyAdded(address indexed stratAddr, uint32 minInterval);
    event StrategyUpdated(address indexed stratAddr);
    event StrategyFactoryUpdated(address indexed factory);
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

    function setStrategyFactory(address factory) external onlyOwner {
        strategyFactory = factory;
        emit StrategyFactoryUpdated(factory);
    }

    function addStrategy(address strat) external onlyStrategyFactory returns (uint256 id) {
        if (strat == address(0)) revert ZeroAddress();
        watched.push(WatchedStrategy({stratAddr: strat, minInterval: DEFAULT_MIN_INTERVAL, lastUpkeep: 0, active: true}));
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

    function getPoolValueSnapshotCount(address strategy) external view override returns (uint256) {
        return _poolValueSnapshots[strategy].length;
    }

    function poolValueSnapshots(address strategy, uint256 index)
        external
        view
        override
        returns (uint256 valueWeth, uint256 uniswapFeesCollected, uint64 timestamp)
    {
        PoolValueSnapshot storage s = _poolValueSnapshots[strategy][index];
        return (s.valueWeth, s.uniswapFeesCollected, s.timestamp);
    }

    function performUpkeep(uint256 id) external nonReentrant onlyOperator {
        _performUpkeep(id);
    }

    function performUpkeepBatch(uint256[] calldata ids) external nonReentrant onlyOperator {
        uint256 len = ids.length;
        uint256 maxId = watched.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] >= maxId) continue;
            _performUpkeep(ids[i]);
        }
    }

    function _performUpkeep(uint256 id) internal {
        if (id >= watched.length) revert BadId();
        WatchedStrategy storage ws = watched[id];
        if (!ws.active || ws.stratAddr == address(0)) return;
        if (ws.lastUpkeep != 0 && ws.minInterval > 0 && uint32(block.timestamp) < ws.lastUpkeep + ws.minInterval) {
            return;
        }
        IOutOfRangeStrategyV3 strat = IOutOfRangeStrategyV3(ws.stratAddr);
        if (strat.mode() == MODE_STABLE) return;
        if (strat.keeperCheck()) {
            ws.lastUpkeep = uint32(block.timestamp);
        }
    }

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
        if (!ws.active || ws.stratAddr == address(0)) return;
        IOutOfRangeStrategyV3 strat = IOutOfRangeStrategyV3(ws.stratAddr);
        if (strat.mode() == MODE_STABLE) return;
        strat.harvestBoolean(skipIncreaseLiquidity);
        emit HarvestPerformed(id, ws.stratAddr, keeper);
        _recordPoolValueSnapshot(ws.stratAddr);
    }

    function snapshotPoolValue(uint256 id) external override nonReentrant onlyOperator {
        _snapshotPoolValue(id);
    }

    function snapshotPoolValueBatch(uint256[] calldata ids) external nonReentrant onlyOperator {
        uint256 len = ids.length;
        uint256 maxId = watched.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] >= maxId) continue;
            _snapshotPoolValue(ids[i]);
        }
    }

    function _snapshotPoolValue(uint256 id) internal {
        if (id >= watched.length) revert BadId();
        WatchedStrategy storage ws = watched[id];
        if (!ws.active || ws.stratAddr == address(0)) return;
        if (IOutOfRangeStrategyV3(ws.stratAddr).mode() == MODE_STABLE) return;
        _recordPoolValueSnapshot(ws.stratAddr);
    }

    function _recordPoolValueSnapshot(address stratAddr) internal {
        IUFloatStrategyV3 strat = IUFloatStrategyV3(stratAddr);
        uint256 pv = strat.totalValueWeth();
        uint256 fees = strat.UniswapFeesCollected();
        uint64 ts = uint64(block.timestamp);
        _poolValueSnapshots[stratAddr].push(
            PoolValueSnapshot({valueWeth: pv, uniswapFeesCollected: fees, timestamp: ts})
        );
    }
}
