// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IOutOfRangeStrategyV4.sol";
import "./interfaces/IFloatV4ContractManager.sol";
import "./interfaces/IFloatVaultV4.sol";

/// @title FloatKeeperV4
/// @notice Same keeper/orchestration as `FloatKeeper`, wired to `FloatVaultV4` via manager key `FloatVaultV4`.
contract FloatKeeperV4 is Ownable, ReentrancyGuard {
    /// @dev Must match `FloatStrategyV4.Mode`: 3 = NEUTRAL, 4 = STABLE (WETH-only idle).
    uint8 private constant MODE_NEUTRAL = 3;
    uint8 private constant MODE_STABLE = 4;

    struct WatchedStrategy {
        address stratAddr;
        uint32 minInterval;
        uint32 lastAction;
        bool active;
    }

    WatchedStrategy[] public watched;

    address public demeterAddr;
    address public _managerAddr;
    IFloatV4ContractManager public manager;

    error Unauthorized();
    event StrategyAdded(address indexed stratAddr, uint32 minInterval);
    event StrategyUpdated(address indexed stratAddr);
    event UpkeepPerformed(
        uint256 indexed id,
        address indexed strat,
        address indexed keeper,
        bool didAct,
        uint8 strategyMode,
        uint256 consecutiveOffensiveCount,
        uint256 defensiveEnteredAt
    );
    event VaultPoolValueSnapshot(address indexed vault, address indexed caller);

    constructor(address _managerAddress) Ownable(msg.sender) {
        _managerAddr = _managerAddress;
        manager = IFloatV4ContractManager(_managerAddress);
        demeterAddr = manager.getAddress("Demeter");
    }

    modifier onlyAuthorized() {
        address s = _msgSender();
        if (s != demeterAddr && s != _managerAddr && s != owner()) revert Unauthorized();
        _;
    }

    function snapshotVaultPoolValue() external onlyAuthorized nonReentrant {
        address vaultAddr = manager.getAddress("FloatVaultV4");
        require(vaultAddr != address(0), "vault=0");
        IFloatVaultV4(vaultAddr).recordPoolValueSnapshot();
        emit VaultPoolValueSnapshot(vaultAddr, _msgSender());
    }

    function addStrategy(address strat, uint32 minInterval) external onlyAuthorized returns (uint256 id) {
        require(strat != address(0), "zero strat");
        watched.push(WatchedStrategy({stratAddr: strat, minInterval: minInterval, lastAction: 0, active: true}));
        id = watched.length - 1;
        emit StrategyAdded(strat, minInterval);
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
        if (strategyMode == MODE_NEUTRAL || strategyMode == MODE_STABLE) {
            emit UpkeepPerformed(
                id, stratAddr, msg.sender, false, strategyMode, strat.consecutiveOffensiveCount(), strat.defensiveEnteredAt()
            );
            return;
        }

        bool keeperCheck = strat.keeperCheck();

        if (!keeperCheck) {
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
        if (strategyMode == MODE_NEUTRAL || strategyMode == MODE_STABLE) {
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
