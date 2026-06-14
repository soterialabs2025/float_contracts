// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IOutOfRangeStrategy.sol";  // Interface for the strategy
import "../interfaces/IContractManager.sol";
import "../interfaces/IFloatVault.sol";

contract FloatKeeper is Ownable, ReentrancyGuard {

    struct WatchedStrategy {
        address stratAddr;        // Strategy contract address
        uint32  minInterval; // Minimum seconds between actions (fits until 2106)
        uint32  lastAction;  // Last time we *acted* on this strategy (fits until 2106)
        bool    active;      // Whether it is monitored
    }

    WatchedStrategy[] public watched;

    address public demeterAddr;
    address public _managerAddr;
    IContractManager public manager;

    error Unauthorized();
    event StrategyAdded(address indexed stratAddr, uint32 minInterval);
    event StrategyUpdated(address indexed stratAddr);
    event StrategyRemoved(address indexed stratAddr, uint256 indexed id);
    event UpkeepPerformed(
        uint256 indexed id,
        address indexed strat,
        address indexed keeper,
        bool    didAct,
        uint8   strategyMode,  // 0=NORMAL, 1=DEFENSIVE, 2=OFFENSIVE
        uint256 consecutiveOffensiveCount,
        uint256 defensiveEnteredAt
    );
    event VaultPoolValueSnapshot(address indexed vault, address indexed caller);

    constructor(address _managerAddress) Ownable(msg.sender) {
      _managerAddr = _managerAddress;
      manager = IContractManager(_managerAddress);
      demeterAddr = manager.getAddress("Demeter");
    }

    // -----------------------------
    // Admin: manage strategies
    // -----------------------------

    modifier onlyAuthorized() {
        address s = _msgSender();
        if (s != demeterAddr && s != _managerAddr && s != owner()) revert Unauthorized();
        _;
    }


    /// @notice Demeter pulls `poolValue()` from the vault’s strategy and stores it on the vault.
    function snapshotVaultPoolValue() external onlyAuthorized nonReentrant {
        address vaultAddr = manager.getAddress("FloatVault");
        require(vaultAddr != address(0), "vault=0");
        IFloatVault(vaultAddr).recordPoolValueSnapshot();
        emit VaultPoolValueSnapshot(vaultAddr, _msgSender());
    }

    function addStrategy(address strat, uint32 minInterval) external onlyAuthorized returns (uint256 id) {
        require(strat != address(0), "zero strat");
        watched.push(WatchedStrategy({
            stratAddr: strat,
            minInterval: minInterval,
            lastAction: 0,
            active: true
        }));
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

    function removeStrategy(uint256 id) external onlyAuthorized {
        require(id < watched.length, "bad id");
        address removed = watched[id].stratAddr;
        uint256 last = watched.length - 1;
        if (id != last) {
            watched[id] = watched[last];
        }
        watched.pop();
        emit StrategyRemoved(removed, id);
    }

    function strategiesLength() external view returns (uint256) {
        return watched.length;
    }

    // -----------------------------
    // Keeper logic
    // -----------------------------

    /// @notice Perform upkeep for a single strategy (by index in `watched`)
    /// @dev Anyone can call this
    function performUpkeep(uint256 id) external nonReentrant {
        require(id < watched.length, "bad id");

        WatchedStrategy storage ws = watched[id];
        address stratAddr = ws.stratAddr; // Cache to avoid multiple storage reads
        
        if (!ws.active || stratAddr == address(0)) {
            emit UpkeepPerformed(id, stratAddr, msg.sender, false, 0, 0, 0);
            return;
        }

        // Respect per-strategy interval (except on very first call)
        uint32 lastAction = ws.lastAction;
        uint32 minInterval = ws.minInterval;
        if (
            lastAction != 0 &&
            minInterval > 0 &&
            uint32(block.timestamp) < lastAction + minInterval
        ) {
            IOutOfRangeStrategy s0 = IOutOfRangeStrategy(stratAddr);
            emit UpkeepPerformed(id, stratAddr, msg.sender, false, s0.mode(), s0.consecutiveOffensiveCount(), s0.defensiveEnteredAt());
            return;
        }

        IOutOfRangeStrategy strat = IOutOfRangeStrategy(stratAddr);

        // Check if we need to perform any action (may transition mode / set defensiveEnteredAt on the strategy)
        bool keeperCheck = strat.keeperCheck();
        
        // If neither condition is met, no action needed
        if (!keeperCheck) {
            emit UpkeepPerformed(id, stratAddr, msg.sender, false, strat.mode(), strat.consecutiveOffensiveCount(), strat.defensiveEnteredAt());
            return;
        }

        // Defensive recovery and idle paths run inside strategy _harvest. Strategy must authorize this keeper (keeperStratAddr).
        try strat.harvestBoolean(true) returns (uint256) {
        } catch {
        }

        ws.lastAction = uint32(block.timestamp);
        emit UpkeepPerformed(id, stratAddr, msg.sender, true, strat.mode(), strat.consecutiveOffensiveCount(), strat.defensiveEnteredAt());
    }

    /// @notice Batch version to allow keepers to touch many strategies in one tx
    function performUpkeepBatch(uint256[] calldata ids) external  {
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; i++) {
            // we intentionally ignore failures per-id and just emit events
            try this.performUpkeep(ids[i]) {
                // no-op
            } catch {
                // avoid revert for whole batch
            }
        }
    }

    /// @notice Harvest a strategy (by index in `watched`)
    /// @dev Anyone can call this
    /// @param id Strategy index in watched array
    /// @param skipIncreaseLiquidity Whether to skip increasing liquidity after harvest
    function performHarvest(uint256 id, bool skipIncreaseLiquidity) external nonReentrant {
        require(id < watched.length, "bad id");

        WatchedStrategy storage ws = watched[id];
        address stratAddr = ws.stratAddr; // Cache to avoid multiple storage reads
        
        if (!ws.active || stratAddr == address(0)) {
            emit UpkeepPerformed(id, stratAddr, msg.sender, false, 0, 0, 0);
            return;
        }

        // Respect per-strategy interval (except on very first call)
        uint32 lastAction = ws.lastAction;
        uint32 minInterval = ws.minInterval;
        if (
            lastAction != 0 &&
            minInterval > 0 &&
            uint32(block.timestamp) < lastAction + minInterval
        ) {
            IOutOfRangeStrategy s0 = IOutOfRangeStrategy(stratAddr);
            emit UpkeepPerformed(id, stratAddr, msg.sender, false, s0.mode(), s0.consecutiveOffensiveCount(), s0.defensiveEnteredAt());
            return;
        }

        IOutOfRangeStrategy strat = IOutOfRangeStrategy(stratAddr);

        try strat.harvestBoolean(skipIncreaseLiquidity) returns (uint256) {
        } catch {
            emit UpkeepPerformed(id, stratAddr, msg.sender, false, strat.mode(), strat.consecutiveOffensiveCount(), strat.defensiveEnteredAt());
            return;
        }

        ws.lastAction = uint32(block.timestamp);
        emit UpkeepPerformed(id, stratAddr, msg.sender, true, strat.mode(), strat.consecutiveOffensiveCount(), strat.defensiveEnteredAt());
    }

    /// @notice Batch harvest for multiple strategies in one tx
    /// @param ids Strategy indices in `watched`
    /// @param skipIncreaseLiquidity Passed through to each `performHarvest`
    function performHarvestBatch(uint256[] calldata ids, bool skipIncreaseLiquidity) external {
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; i++) {
            try this.performHarvest(ids[i], skipIncreaseLiquidity) {} catch {}
        }
    }
}
