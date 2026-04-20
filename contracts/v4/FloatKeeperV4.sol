// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../../interfaces/IOutOfRangeStrategy.sol";
import "../../interfaces/IContractManager.sol";
import "../../interfaces/IFloatVault.sol";

/// @title FloatKeeperV4
/// @notice Same keeper/orchestration as `FloatKeeper`, wired to `FloatVaultV4` via manager key `FloatVaultV4`.
contract FloatKeeperV4 is Ownable, ReentrancyGuard {
    struct WatchedStrategy {
        address stratAddr;
        uint32 minInterval;
        uint32 lastAction;
        bool active;
    }

    WatchedStrategy[] public watched;

    address public demeterAddr;
    address public _managerAddr;
    IContractManager public manager;

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
        manager = IContractManager(_managerAddress);
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
        IFloatVault(vaultAddr).recordPoolValueSnapshot();
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
            IOutOfRangeStrategy s0 = IOutOfRangeStrategy(stratAddr);
            emit UpkeepPerformed(
                id, stratAddr, msg.sender, false, s0.mode(), s0.consecutiveOffensiveCount(), s0.defensiveEnteredAt()
            );
            return;
        }

        IOutOfRangeStrategy strat = IOutOfRangeStrategy(stratAddr);

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
            IOutOfRangeStrategy s0 = IOutOfRangeStrategy(stratAddr);
            emit UpkeepPerformed(
                id, stratAddr, msg.sender, false, s0.mode(), s0.consecutiveOffensiveCount(), s0.defensiveEnteredAt()
            );
            return;
        }

        IOutOfRangeStrategy strat = IOutOfRangeStrategy(stratAddr);

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
