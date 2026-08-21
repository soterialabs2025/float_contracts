// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IOperatorRegistry.sol";
import "./interfaces/IUFloatStrategyV4.sol";

/// @notice Watches UFloatStrategy clones; operators call upkeep/harvest (supports many signer wallets).
contract UFloatKeeperV4 is Ownable, ReentrancyGuard {
    error Unauthorized();
    error ZeroAddress();
    error BadId();

    uint32 public constant DEFAULT_MIN_INTERVAL = 0;

    struct WatchedStrategy {
        address stratAddr;
        uint32 minInterval;
        uint32 lastAction;
        bool active;
    }

    IOperatorRegistry public immutable operatorRegistry;
    WatchedStrategy[] public watched;

    address public strategyFactory;

    event StrategyAdded(address indexed stratAddr, uint32 minInterval);
    event StrategyUpdated(address indexed stratAddr, bool active, uint32 minInterval);
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

    constructor(address operatorRegistry_) {
        if (operatorRegistry_ == address(0)) revert ZeroAddress();
        operatorRegistry = IOperatorRegistry(operatorRegistry_);
    }

    function strategiesLength() external view returns (uint256) {
        return watched.length;
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
        if (factory == address(0)) revert ZeroAddress();
        strategyFactory = factory;
        emit StrategyFactoryUpdated(factory);
    }

    function addStrategy(address strat) external onlyStrategyFactory returns (uint256 id) {
        if (strat == address(0)) revert ZeroAddress();
        watched.push(
            WatchedStrategy({
                stratAddr: strat,
                minInterval: DEFAULT_MIN_INTERVAL,
                lastAction: 0,
                active: true
            })
        );
        id = watched.length - 1;
        emit StrategyAdded(strat, DEFAULT_MIN_INTERVAL);
    }

    function updateStrategy(uint256 id, bool active, uint32 minInterval) external onlyOperator {
        if (id >= watched.length) revert BadId();
        WatchedStrategy storage ws = watched[id];
        ws.active = active;
        ws.minInterval = minInterval;
        emit StrategyUpdated(ws.stratAddr, active, minInterval);
    }

    function performUpkeepBatch(uint256[] calldata ids) external nonReentrant onlyOperator {
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; ++i) {
            _performUpkeep(ids[i]);
        }
    }

    function performUpkeep(uint256 id) external nonReentrant onlyOperator {
        _performUpkeep(id);
    }

    function _performUpkeep(uint256 id) internal {
        if (id >= watched.length) revert BadId();

        WatchedStrategy storage ws = watched[id];
        address stratAddr = ws.stratAddr;

        if (!ws.active || stratAddr == address(0)) {
            emit UpkeepPerformed(id, stratAddr, msg.sender, false, 0, 0, 0);
            return;
        }

        uint32 lastAction = ws.lastAction;
        uint32 minInterval = ws.minInterval;
        if (
            lastAction != 0 &&
            minInterval > 0 &&
            uint32(block.timestamp) < lastAction + minInterval
        ) {
            IUFloatStrategyV4 s0 = IUFloatStrategyV4(stratAddr);
            emit UpkeepPerformed(
                id,
                stratAddr,
                msg.sender,
                false,
                s0.mode(),
                s0.consecutiveOffensiveCount(),
                s0.defensiveEnteredAt()
            );
            return;
        }

        IUFloatStrategyV4 strat = IUFloatStrategyV4(stratAddr);
        bool didAct = strat.keeperCheck();

        if (didAct) {
            ws.lastAction = uint32(block.timestamp);
        }

        emit UpkeepPerformed(
            id,
            stratAddr,
            msg.sender,
            didAct,
            strat.mode(),
            strat.consecutiveOffensiveCount(),
            strat.defensiveEnteredAt()
        );
    }

    function performHarvestBatch(uint256[] calldata ids, bool skipIncreaseLiquidity) external nonReentrant onlyOperator {
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; ++i) {
            _performHarvest(ids[i], skipIncreaseLiquidity);
        }
    }

    function performHarvest(uint256 id, bool skipIncreaseLiquidity) external nonReentrant onlyOperator {
        _performHarvest(id, skipIncreaseLiquidity);
    }

    function _performHarvest(uint256 id, bool skipIncreaseLiquidity) internal {
        if (id >= watched.length) revert BadId();

        WatchedStrategy storage ws = watched[id];
        address stratAddr = ws.stratAddr;

        if (!ws.active || stratAddr == address(0)) {
            emit HarvestPerformed(id, stratAddr, msg.sender);
            return;
        }

        uint32 lastAction = ws.lastAction;
        uint32 minInterval = ws.minInterval;
        if (
            lastAction != 0 &&
            minInterval > 0 &&
            uint32(block.timestamp) < lastAction + minInterval
        ) {
            emit HarvestPerformed(id, stratAddr, msg.sender);
            return;
        }

        IUFloatStrategyV4 strat = IUFloatStrategyV4(stratAddr);
        try strat.harvestBoolean(skipIncreaseLiquidity) returns (uint256) {
            ws.lastAction = uint32(block.timestamp);
        } catch {}

        emit HarvestPerformed(id, stratAddr, msg.sender);
    }
}
