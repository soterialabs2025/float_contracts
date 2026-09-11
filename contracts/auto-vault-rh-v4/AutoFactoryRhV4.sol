// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./libraries/LiquidityLibraryV4.sol";
import "./AutoStrategyManagerRhV4.sol";
import "./AutoStrategyRhV4.sol";
import "./AutoVaultRhV4.sol";
import "./LiquidSharesRhV4.sol";
import "./ShareStakingRhV4.sol";
import "./interfaces/IAutoSwapRouterRhV4.sol";
import "./interfaces/IAutoKeeperRhV4.sol";
import "./interfaces/IAutoOperatorRegistryRhV4.sol";

/// @title AutoFactoryRhV4
/// @notice RH (4663) deploys AutoStrategyRhV4 + AutoVaultRhV4 + LiquidSharesRhV4 clones and a fresh ShareStakingRhV4 per package.
contract AutoFactoryRhV4 is Ownable, ReentrancyGuard {
    using Clones for address;

    struct InfraConfig {
        address swapRouter;
        address operatorRegistry;
        address keeper;
        address feeManager;
    }

    struct VaultRegistry {
        address strategy;
        address vault;
        address liquidShares;
        address shareStaking;
        bool active;
    }

    InfraConfig public infra;
    address public immutable strategyImplementation;
    address public immutable vaultImplementation;
    address public immutable liquidSharesImplementation;

    mapping(address => VaultRegistry) public registry;
    address[] public assets;

    error ZeroAddress();
    error InvalidPoolKey();
    error AlreadyDeployed();
    error Unauthorized();
    error OwnerMismatch();
    error UnknownPackage();
    error PackageOwnershipLocked();
    error AssetIsShares();

    modifier onlyOperator() {
        if (!IAutoOperatorRegistryRhV4(infra.operatorRegistry).isOperator(msg.sender) && msg.sender != owner()) {
            revert Unauthorized();
        }
        _;
    }

    event VaultRegistryDeployed(
        address indexed strategy,
        address indexed vault,
        address indexed liquidShares,
        address shareStaking,
        address asset,
        address owner,
        uint256 keeperId
    );
    event VaultRegistryUpdated(address indexed asset, address strategy, address vault, bool active);
    event PackageOwnershipTransferred(address indexed asset, address indexed previousOwner, address indexed newOwner);
    event InfraUpdated(
        address indexed swapRouter, address indexed operatorRegistry, address indexed keeper, address feeManager
    );

    constructor(InfraConfig memory config) Ownable(msg.sender) {
        _validateInfra(config);
        infra = config;
        strategyImplementation = address(new AutoStrategyRhV4(address(this)));
        vaultImplementation = address(new AutoVaultRhV4(address(this)));
        liquidSharesImplementation = address(new LiquidSharesRhV4(address(this)));
    }

    function updateInfra(InfraConfig calldata config) external onlyOwner {
        _validateInfra(config);
        infra = config;
        emit InfraUpdated(config.swapRouter, config.operatorRegistry, config.keeper, config.feeManager);
    }

    function assetsLength() external view returns (uint256) {
        return assets.length;
    }

    /// @notice Toggle registry `active` for an already-deployed package.
    function setPackageActive(address asset, bool active) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        VaultRegistry storage pkg = registry[asset];
        if (pkg.strategy == address(0)) revert UnknownPackage();
        pkg.active = active;
        emit VaultRegistryUpdated(asset, pkg.strategy, pkg.vault, active);
    }

    /// @notice Deploy package against a token/native-ETH PoolKey (`currency0 = address(0)`).
    /// @param bands Outer/inner widths in ticks; must be positive multiples of `key.tickSpacing`.
    function deployVaultPackage(
        address asset,
        LiquidityLibraryV4.PoolKey calldata key,
        bytes calldata hookData,
        AutoStrategyManagerRhV4.BandConfig calldata bands
    )
        external
        onlyOperator
        nonReentrant
        returns (address strategy, address vault, address liquidShares, address shareStaking, uint256 keeperId)
    {
        if (asset == address(0)) revert ZeroAddress();
        if (registry[asset].strategy != address(0)) revert AlreadyDeployed();

        // token/ETH v4: native ETH is always currency0 (address(0) sorts first).
        if (key.tickSpacing <= 0 || key.currency0 != address(0) || key.currency1 != asset) {
            revert InvalidPoolKey();
        }

        strategy = strategyImplementation.clone();
        vault = vaultImplementation.clone();
        liquidShares = liquidSharesImplementation.clone();
        shareStaking = address(new ShareStakingRhV4(address(this)));
        if (asset == liquidShares) revert AssetIsShares();

        LiquidSharesRhV4(liquidShares).bootstrap(vault);
        ShareStakingRhV4(payable(shareStaking)).bootstrap(
            msg.sender, liquidShares, strategy, asset, infra.swapRouter, key, hookData
        );
        AutoVaultRhV4(payable(vault)).bootstrap(msg.sender, strategy, liquidShares, shareStaking, asset);
        AutoStrategyRhV4(payable(strategy)).bootstrap(
            msg.sender,
            vault,
            infra.swapRouter,
            infra.operatorRegistry,
            infra.keeper,
            infra.feeManager,
            shareStaking,
            asset,
            key,
            hookData,
            bands
        );

        IAutoSwapRouterRhV4(infra.swapRouter).addAuthorizedStrategy(strategy);
        IAutoSwapRouterRhV4(infra.swapRouter).addAuthorizedStrategy(shareStaking);
        keeperId = IAutoKeeperRhV4(infra.keeper).addStrategy(strategy);

        registry[asset] = VaultRegistry(strategy, vault, liquidShares, shareStaking, true);
        assets.push(asset);

        emit VaultRegistryDeployed(strategy, vault, liquidShares, shareStaking, asset, msg.sender, keeperId);
        emit VaultRegistryUpdated(asset, strategy, vault, true);
    }

    /// @notice One-shot transfer of package admin ownership (vault + strategy + ShareStakingRhV4) to `newOwner`.
    function transferPackageOwnership(address asset, address newOwner) external nonReentrant {
        if (asset == address(0) || newOwner == address(0)) revert ZeroAddress();
        VaultRegistry memory pkg = registry[asset];
        if (pkg.strategy == address(0) || pkg.vault == address(0) || pkg.shareStaking == address(0)) {
            revert UnknownPackage();
        }

        if (
            AutoVaultRhV4(payable(pkg.vault)).ownershipLocked()
                || AutoStrategyRhV4(payable(pkg.strategy)).ownershipLocked()
                || ShareStakingRhV4(payable(pkg.shareStaking)).ownershipLocked()
        ) revert PackageOwnershipLocked();

        address vaultOwner = AutoVaultRhV4(payable(pkg.vault)).owner();
        address strategyOwner = AutoStrategyRhV4(payable(pkg.strategy)).owner();
        address stakingOwner = ShareStakingRhV4(payable(pkg.shareStaking)).owner();
        if (vaultOwner != strategyOwner || strategyOwner != stakingOwner) revert OwnerMismatch();

        if (msg.sender != vaultOwner && msg.sender != owner()) revert Unauthorized();

        AutoVaultRhV4(payable(pkg.vault)).transferOwnershipFromFactory(newOwner);
        AutoStrategyRhV4(payable(pkg.strategy)).transferOwnershipFromFactory(newOwner);
        ShareStakingRhV4(payable(pkg.shareStaking)).transferOwnershipFromFactory(newOwner);

        emit PackageOwnershipTransferred(asset, vaultOwner, newOwner);
    }

    function _validateInfra(InfraConfig memory config) private pure {
        if (
            config.swapRouter == address(0) || config.operatorRegistry == address(0) || config.keeper == address(0)
                || config.feeManager == address(0)
        ) revert ZeroAddress();
    }
}
