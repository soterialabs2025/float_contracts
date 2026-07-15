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
        address stratAddr = ws.stratAddr;
        
        if (!ws.active || stratAddr == address(0)) {
            return;
        }

        uint32 lastAction = ws.lastAction;
        uint32 minInterval = ws.minInterval;
        if (
            lastAction != 0 &&
            minInterval > 0 &&
            uint32(block.timestamp) < lastAction + minInterval
        ) {
            return;
        }

        IOutOfRangeStrategy strat = IOutOfRangeStrategy(stratAddr);

        // OOR remint / mode transitions happen inside keeperCheck.
        if (!strat.keeperCheck()) {
            return;
        }

        // Fee collect is via `performHarvest` on a separate cadence — not every upkeep.
        ws.lastAction = uint32(block.timestamp);
    }

    /// @notice Batch version to allow keepers to touch many strategies in one tx
    function performUpkeepBatch(uint256[] calldata ids) external  {
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; i++) {
            try this.performUpkeep(ids[i]) {} catch {}
        }
    }

    /// @notice Harvest a strategy (by index in `watched`)
    /// @dev Anyone can call this
    /// @param id Strategy index in watched array
    /// @param skipIncreaseLiquidity Whether to skip increasing liquidity after harvest
    function performHarvest(uint256 id, bool skipIncreaseLiquidity) external nonReentrant {
        require(id < watched.length, "bad id");

        WatchedStrategy storage ws = watched[id];
        address stratAddr = ws.stratAddr;
        
        if (!ws.active || stratAddr == address(0)) {
            return;
        }

        uint32 lastAction = ws.lastAction;
        uint32 minInterval = ws.minInterval;
        if (
            lastAction != 0 &&
            minInterval > 0 &&
            uint32(block.timestamp) < lastAction + minInterval
        ) {
            return;
        }

        IOutOfRangeStrategy strat = IOutOfRangeStrategy(stratAddr);

        try strat.harvestBoolean(skipIncreaseLiquidity) returns (uint256) {
        } catch {
            return;
        }

        ws.lastAction = uint32(block.timestamp);
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
