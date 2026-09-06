// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IAutoKeeperRhV4.sol";
import "./interfaces/IAutoOperatorRegistryRhV4.sol";
import "./interfaces/IAutoStrategyRhV4.sol";
import "./interfaces/IAutoVaultRhV4.sol";

/// @title AutoKeeperRhV4
/// @notice Upkeep = remint path only (`keeperCheck`); harvest is a separate cadence.
contract AutoKeeperRhV4 is IAutoKeeperRhV4, Ownable, ReentrancyGuard {
    uint32 public constant DEFAULT_MIN_INTERVAL = 3;

    struct WatchedStrategy {
        address stratAddr;
        uint32 minInterval;
        uint32 lastUpkeep;
        uint32 lastHarvest;
        bool active;
    }

    IAutoOperatorRegistryRhV4 public immutable operatorRegistry;
    WatchedStrategy[] public watched;
    address public strategyFactory;

    error Unauthorized();
    error ZeroAddress();
    error BadId();

    event StrategyAdded(address indexed stratAddr, uint32 minInterval);
    event StrategyFactoryUpdated(address indexed factory);
    event VaultPoolValueSnapshot(uint256 indexed id, address indexed vault, address indexed strat, address caller);

    constructor(address operatorRegistry_) Ownable(msg.sender) {
        if (operatorRegistry_ == address(0)) revert ZeroAddress();
        operatorRegistry = IAutoOperatorRegistryRhV4(operatorRegistry_);
    }

    modifier onlyOperator() {
        if (!operatorRegistry.isOperator(msg.sender) && msg.sender != owner()) revert Unauthorized();
        _;
    }

    modifier onlyStrategyFactory() {
        if (msg.sender != strategyFactory && msg.sender != owner()) revert Unauthorized();
        _;
    }

    function setStrategyFactory(address factory) external override onlyOwner {
        strategyFactory = factory;
        emit StrategyFactoryUpdated(factory);
    }

    function addStrategy(address strat) external override onlyStrategyFactory returns (uint256 id) {
        if (strat == address(0)) revert ZeroAddress();
        watched.push(
            WatchedStrategy({
                stratAddr: strat, minInterval: DEFAULT_MIN_INTERVAL, lastUpkeep: 0, lastHarvest: 0, active: true
            })
        );
        id = watched.length - 1;
        IAutoStrategyRhV4(strat).setWatched(true);
        emit StrategyAdded(strat, DEFAULT_MIN_INTERVAL);
    }

    function strategiesLength() external view returns (uint256) {
        return watched.length;
    }

    function updateStrategy(uint256 id, bool active, uint32 minInterval) external onlyOperator {
        if (id >= watched.length) revert BadId();
        WatchedStrategy storage ws = watched[id];
        ws.active = active;
        ws.minInterval = minInterval;
    }

    function performUpkeep(uint256 id) external override nonReentrant onlyOperator {
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
        if (IAutoStrategyRhV4(ws.stratAddr).keeperCheck()) {
            ws.lastUpkeep = uint32(block.timestamp);
        }
    }

    /// @notice Refresh the truncated price reference on `id`. Cheap, swap-free, and rate-limited in the strategy.
    /// @dev Run this on a five-minute cadence, independent of `performUpkeep`, which only lands when the position
    ///      needs work. The reference both prices share minting and anchors the swap gate, and because its
    ///      movement is capped per unit time, a denser cadence is what bounds one poisoned write.
    function refreshPriceRef(uint256 id) external nonReentrant onlyOperator {
        _refreshPriceRef(id);
    }

    /// @notice Batch form. One transaction across every watched strategy amortises the base cost at that cadence.
    function refreshPriceRefBatch(uint256[] calldata ids) external nonReentrant onlyOperator {
        uint256 len = ids.length;
        uint256 maxId = watched.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] >= maxId) continue;
            _refreshPriceRef(ids[i]);
        }
    }

    function _refreshPriceRef(uint256 id) internal {
        if (id >= watched.length) revert BadId();
        WatchedStrategy storage ws = watched[id];
        if (!ws.active || ws.stratAddr == address(0)) return;
        IAutoStrategyRhV4(ws.stratAddr).refreshPriceRef();
    }

    function performHarvest(uint256 id, bool skipIncreaseLiquidity) external override nonReentrant onlyOperator {
        _performHarvest(id, skipIncreaseLiquidity);
    }

    function performHarvestBatch(uint256[] calldata ids, bool skipIncreaseLiquidity)
        external
        nonReentrant
        onlyOperator
    {
        uint256 len = ids.length;
        uint256 maxId = watched.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] >= maxId) continue;
            _performHarvest(ids[i], skipIncreaseLiquidity);
        }
    }

    function _performHarvest(uint256 id, bool skipIncreaseLiquidity) internal {
        if (id >= watched.length) revert BadId();
        WatchedStrategy storage ws = watched[id];
        if (!ws.active || ws.stratAddr == address(0)) return;
        IAutoStrategyRhV4(ws.stratAddr).harvestBoolean(skipIncreaseLiquidity);
        ws.lastHarvest = uint32(block.timestamp);
        _recordVaultPoolValueSnapshot(ws.stratAddr);
    }

    function snapshotVaultPoolValue(uint256 id) external override nonReentrant onlyOperator {
        _snapshotVaultPoolValue(id);
    }

    function snapshotVaultPoolValueBatch(uint256[] calldata ids) external nonReentrant onlyOperator {
        uint256 len = ids.length;
        uint256 maxId = watched.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] >= maxId) continue;
            _snapshotVaultPoolValue(ids[i]);
        }
    }

    function _snapshotVaultPoolValue(uint256 id) internal {
        if (id >= watched.length) revert BadId();
        WatchedStrategy storage ws = watched[id];
        if (!ws.active || ws.stratAddr == address(0)) return;
        _recordVaultPoolValueSnapshot(ws.stratAddr);
    }

    function _recordVaultPoolValueSnapshot(address stratAddr) internal {
        address vaultAddr = IAutoStrategyRhV4(stratAddr).vault();
        if (vaultAddr == address(0)) revert ZeroAddress();
        IAutoVaultRhV4(vaultAddr).recordPoolValueSnapshot();
    }
}
