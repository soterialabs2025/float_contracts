// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./libraries/LiquidityLibraryV4.sol";
import "../v4/V4Deployments8453.sol";
import "./AutoStrategyBv4.sol";
import "./AutoVaultBv4.sol";
import "./LiquidSharesBv4.sol";
import "./ShareStakingBv4.sol";
import "./interfaces/IAutoSwapRouterBv4.sol";
import "./interfaces/IAutoKeeperBv4.sol";
import "./interfaces/IAutoOperatorRegistryBv4.sol";

/// @title AutoFactoryBv4
/// @notice Base (8453) deploys AutoStrategyBv4 + AutoVaultBv4 + LiquidSharesBv4 + ShareStakingBv4 packages.
contract AutoFactoryBv4 is Ownable, ReentrancyGuard {
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
    address public immutable shareStakingImplementation;

    mapping(address => VaultRegistry) public registry;
    address[] public assets;

    error ZeroAddress();
    error InvalidPoolKey();
    error AlreadyDeployed();
    error Unauthorized();
    error OwnerMismatch();
    error UnknownPackage();
    error PackageOwnershipLocked();

    modifier onlyOperator() {
        if (!IAutoOperatorRegistryBv4(infra.operatorRegistry).isOperator(msg.sender) && msg.sender != owner()) {
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
        strategyImplementation = address(new AutoStrategyBv4(address(this)));
        vaultImplementation = address(new AutoVaultBv4(address(this)));
        liquidSharesImplementation = address(new LiquidSharesBv4(address(this)));
        shareStakingImplementation = address(new ShareStakingBv4(address(this)));
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

    /// @notice Deploy package against a manual ASSET/WETH PoolKey (not native ETH address(0)).
    function deployVaultPackage(address asset, LiquidityLibraryV4.PoolKey calldata key, bytes calldata hookData)
        external
        onlyOperator
        nonReentrant
        returns (address strategy, address vault, address liquidShares, address shareStaking, uint256 keeperId)
    {
        if (asset == address(0)) revert ZeroAddress();
        if (registry[asset].strategy != address(0)) revert AlreadyDeployed();

        address weth = V4Deployments8453.WETH;
        if (key.currency0 == address(0) || key.currency1 == address(0)) revert InvalidPoolKey();
        if (
            !((key.currency0 == asset && key.currency1 == weth)
                || (key.currency1 == asset && key.currency0 == weth))
        ) revert InvalidPoolKey();

        strategy = strategyImplementation.clone();
        vault = vaultImplementation.clone();
        liquidShares = liquidSharesImplementation.clone();
        shareStaking = shareStakingImplementation.clone();

        LiquidSharesBv4(liquidShares).bootstrap(vault);
        ShareStakingBv4(shareStaking).bootstrap(
            msg.sender, liquidShares, strategy, asset, infra.swapRouter, key, hookData
        );
        AutoVaultBv4(payable(vault)).bootstrap(msg.sender, strategy, liquidShares, shareStaking, asset);
        AutoStrategyBv4(payable(strategy)).bootstrap(
            msg.sender,
            vault,
            infra.swapRouter,
            infra.operatorRegistry,
            infra.keeper,
            infra.feeManager,
            shareStaking,
            asset,
            key,
            hookData
        );

        IAutoSwapRouterBv4(infra.swapRouter).addAuthorizedStrategy(strategy);
        IAutoSwapRouterBv4(infra.swapRouter).addAuthorizedStrategy(shareStaking);
        keeperId = IAutoKeeperBv4(infra.keeper).addStrategy(strategy);

        registry[asset] = VaultRegistry(strategy, vault, liquidShares, shareStaking, true);
        assets.push(asset);

        emit VaultRegistryDeployed(strategy, vault, liquidShares, shareStaking, asset, msg.sender, keeperId);
        emit VaultRegistryUpdated(asset, strategy, vault, true);
    }

    /// @notice One-shot transfer of package admin ownership (vault + strategy + ShareStakingBv4) to `newOwner`.
    function transferPackageOwnership(address asset, address newOwner) external nonReentrant {
        if (asset == address(0) || newOwner == address(0)) revert ZeroAddress();
        VaultRegistry memory pkg = registry[asset];
        if (pkg.strategy == address(0) || pkg.vault == address(0) || pkg.shareStaking == address(0)) {
            revert UnknownPackage();
        }

        if (
            AutoVaultBv4(payable(pkg.vault)).ownershipLocked()
                || AutoStrategyBv4(payable(pkg.strategy)).ownershipLocked()
                || ShareStakingBv4(pkg.shareStaking).ownershipLocked()
        ) revert PackageOwnershipLocked();

        address vaultOwner = AutoVaultBv4(payable(pkg.vault)).owner();
        address strategyOwner = AutoStrategyBv4(payable(pkg.strategy)).owner();
        address stakingOwner = ShareStakingBv4(pkg.shareStaking).owner();
        if (vaultOwner != strategyOwner || strategyOwner != stakingOwner) revert OwnerMismatch();

        if (msg.sender != vaultOwner && msg.sender != owner()) revert Unauthorized();

        AutoVaultBv4(payable(pkg.vault)).transferOwnershipFromFactory(newOwner);
        AutoStrategyBv4(payable(pkg.strategy)).transferOwnershipFromFactory(newOwner);
        ShareStakingBv4(pkg.shareStaking).transferOwnershipFromFactory(newOwner);

        emit PackageOwnershipTransferred(asset, vaultOwner, newOwner);
    }

    function _validateInfra(InfraConfig memory config) private pure {
        if (
            config.swapRouter == address(0) || config.operatorRegistry == address(0) || config.keeper == address(0)
                || config.feeManager == address(0)
        ) revert ZeroAddress();
    }
}
