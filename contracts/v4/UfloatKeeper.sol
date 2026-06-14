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

    address public tritonAddr;
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
    event HarvestPerformed(uint256 indexed id, address indexed strat, address indexed keeper);

    constructor(address _tritonAddr) Ownable(msg.sender) {
        if (_tritonAddr == address(0)) revert ZeroAddress();
        tritonAddr = _tritonAddr;
    }

    modifier onlyAuthorized() {
        address s = _msgSender();
        if (s != tritonAddr && s != owner() && s != strategyFactory) revert Unauthorized();
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
        _performUpkeep(id, msg.sender);
    }

    function performUpkeepBatch(uint256[] calldata ids) external nonReentrant {
        uint256 len = ids.length;
        uint256 maxId = watched.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] >= maxId) continue;
            _performUpkeep(ids[i], msg.sender);
        }
    }

    function _performUpkeep(uint256 id, address keeper) internal {
        require(id < watched.length, "bad id");

        WatchedStrategy storage ws = watched[id];
        address stratAddr = ws.stratAddr;

        if (!ws.active || stratAddr == address(0)) {
            emit UpkeepPerformed(id, stratAddr, keeper, false, 0, 0, 0);
            return;
        }

        uint32 lastAction = ws.lastAction;
        uint32 minInterval = ws.minInterval;
        if (lastAction != 0 && minInterval > 0 && uint32(block.timestamp) < lastAction + minInterval) {
            return;
        }

        IOutOfRangeStrategyV4 strat = IOutOfRangeStrategyV4(stratAddr);

        if (strat.mode() == MODE_STABLE) {
            return;
        }

        bool didAct = strat.keeperCheck();
        if (didAct) {
            ws.lastAction = uint32(block.timestamp);
        }
    }

    function performHarvest(uint256 id, bool skipIncreaseLiquidity) external nonReentrant {
        require(id < watched.length, "bad id");

        WatchedStrategy storage ws = watched[id];
        if (!ws.active || ws.stratAddr == address(0)) return;

        uint32 lastAction = ws.lastAction;
        uint32 minInterval = ws.minInterval;
        if (lastAction != 0 && minInterval > 0 && uint32(block.timestamp) < lastAction + minInterval) {
            return;
        }

        IOutOfRangeStrategyV4 strat = IOutOfRangeStrategyV4(ws.stratAddr);
        if (strat.mode() == MODE_STABLE) return;

        try strat.harvestBoolean(skipIncreaseLiquidity) returns (uint256) {
            ws.lastAction = uint32(block.timestamp);
            emit HarvestPerformed(id, ws.stratAddr, msg.sender);
        } catch {}
    }

    function performHarvestBatch(uint256[] calldata ids, bool skipIncreaseLiquidity) external nonReentrant {
        uint256 len = ids.length;
        uint256 maxId = watched.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] >= maxId) continue;
            _performHarvest(ids[i], skipIncreaseLiquidity);
        }
    }

    function _performHarvest(uint256 id, bool skipIncreaseLiquidity) internal {
        require(id < watched.length, "bad id");

        WatchedStrategy storage ws = watched[id];
        if (!ws.active || ws.stratAddr == address(0)) return;

        uint32 lastAction = ws.lastAction;
        uint32 minInterval = ws.minInterval;
        if (lastAction != 0 && minInterval > 0 && uint32(block.timestamp) < lastAction + minInterval) {
            return;
        }

        IOutOfRangeStrategyV4 strat = IOutOfRangeStrategyV4(ws.stratAddr);
        if (strat.mode() == MODE_STABLE) return;

        try strat.harvestBoolean(skipIncreaseLiquidity) returns (uint256) {
            ws.lastAction = uint32(block.timestamp);
            emit HarvestPerformed(id, ws.stratAddr, msg.sender);
        } catch {}
    }
}
