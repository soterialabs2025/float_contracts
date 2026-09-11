// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./V3Deployments4663.sol";
import "./AutoStrategyRhV3.sol";
import "./AutoVaultRhV3.sol";
import "./LiquidSharesRhV3.sol";
import "./ShareStakingRhV3.sol";
import "./interfaces/IAutoSwapRouterRhV3.sol";
import "./interfaces/IAutoKeeperRhV3.sol";
import "./interfaces/IAutoOperatorRegistryRhV3.sol";
import "./interfaces/IUniswapV3Factory.sol";

contract AutoFactoryRhV3 is Ownable, ReentrancyGuard {
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
        uint24 poolFee;
        bool active;
    }

    InfraConfig public infra;
    address public immutable strategyImplementation;
    address public immutable vaultImplementation;
    address public immutable liquidSharesImplementation;
    mapping(address => VaultRegistry) public registry;
    address[] public assets;

    error ZeroAddress();
    error InvalidPool();
    error AlreadyDeployed();
    error Unauthorized();
    error OwnerMismatch();
    error UnknownPackage();
    error PackageOwnershipLocked();
    error AssetIsShares();

    event VaultRegistryDeployed(
        address indexed strategy,
        address indexed vault,
        address indexed liquidShares,
        address shareStaking,
        address asset,
        uint24 poolFee,
        address owner,
        uint256 keeperId
    );
    event VaultRegistryUpdated(address indexed asset, address strategy, address vault, bool active);
    event PackageOwnershipTransferred(
        address indexed asset, address indexed previousOwner, address indexed newOwner
    );
    event InfraUpdated(
        address indexed swapRouter, address indexed operatorRegistry, address indexed keeper, address feeManager
    );

    constructor(InfraConfig memory config) Ownable(msg.sender) {
        _validateInfra(config);
        infra = config;
        strategyImplementation = address(new AutoStrategyRhV3(address(this)));
        vaultImplementation = address(new AutoVaultRhV3(address(this)));
        liquidSharesImplementation = address(new LiquidSharesRhV3(address(this)));
    }

    modifier onlyOperator() {
        if (!IAutoOperatorRegistryRhV3(infra.operatorRegistry).isOperator(msg.sender) && msg.sender != owner()) {
            revert Unauthorized();
        }
        _;
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

    function deployVaultPackage(address asset, uint24 poolFee)
        external
        onlyOperator
        nonReentrant
        returns (address strategy, address vault, address liquidShares, address shareStaking, uint256 keeperId)
    {
        if (asset == address(0)) revert ZeroAddress();
        if (registry[asset].strategy != address(0)) revert AlreadyDeployed();
        if (IUniswapV3Factory(V3Deployments4663.FACTORY).getPool(asset, V3Deployments4663.WETH, poolFee) == address(0))
        {
            revert InvalidPool();
        }

        strategy = strategyImplementation.clone();
        vault = vaultImplementation.clone();
        liquidShares = liquidSharesImplementation.clone();
        shareStaking = address(new ShareStakingRhV3(address(this)));
        if (asset == liquidShares) revert AssetIsShares();

        LiquidSharesRhV3(liquidShares).bootstrap(vault);
        ShareStakingRhV3(shareStaking).bootstrap(
            msg.sender, liquidShares, strategy, asset, infra.swapRouter, poolFee
        );
        AutoVaultRhV3(payable(vault)).bootstrap(msg.sender, strategy, liquidShares, shareStaking, asset);
        AutoStrategyRhV3(payable(strategy)).bootstrap(
            msg.sender,
            vault,
            infra.swapRouter,
            infra.operatorRegistry,
            infra.keeper,
            infra.feeManager,
            shareStaking,
            asset,
            poolFee
        );

        IAutoSwapRouterRhV3(infra.swapRouter).addAuthorizedStrategy(strategy);
        // ShareStakingRhV3 swaps ASSET→WETH for epoch rewards via the same router whitelist.
        IAutoSwapRouterRhV3(infra.swapRouter).addAuthorizedStrategy(shareStaking);
        keeperId = IAutoKeeperRhV3(infra.keeper).addStrategy(strategy);

        registry[asset] = VaultRegistry(strategy, vault, liquidShares, shareStaking, poolFee, true);
        assets.push(asset);
        emit VaultRegistryDeployed(
            strategy, vault, liquidShares, shareStaking, asset, poolFee, msg.sender, keeperId
        );
        emit VaultRegistryUpdated(asset, strategy, vault, true);
    }

    /// @notice One-shot transfer of package admin ownership (vault + strategy + ShareStakingRhV3) to `newOwner`.
    /// @dev After this call, ownership is locked on those contracts (NFT/TBA control stays with whoever holds the NFT).
    ///      Caller must be the current owner of all three (or the factory owner). Does not move LiquidSharesRhV3.
    function transferPackageOwnership(address asset, address newOwner) external nonReentrant {
        if (asset == address(0) || newOwner == address(0)) revert ZeroAddress();
        VaultRegistry memory pkg = registry[asset];
        if (pkg.strategy == address(0) || pkg.vault == address(0) || pkg.shareStaking == address(0)) {
            revert UnknownPackage();
        }

        if (
            AutoVaultRhV3(payable(pkg.vault)).ownershipLocked()
                || AutoStrategyRhV3(payable(pkg.strategy)).ownershipLocked()
                || ShareStakingRhV3(pkg.shareStaking).ownershipLocked()
        ) revert PackageOwnershipLocked();

        address vaultOwner = AutoVaultRhV3(payable(pkg.vault)).owner();
        address strategyOwner = AutoStrategyRhV3(payable(pkg.strategy)).owner();
        address stakingOwner = ShareStakingRhV3(pkg.shareStaking).owner();
        if (vaultOwner != strategyOwner || strategyOwner != stakingOwner) revert OwnerMismatch();

        if (msg.sender != vaultOwner && msg.sender != owner()) revert Unauthorized();

        AutoVaultRhV3(payable(pkg.vault)).transferOwnershipFromFactory(newOwner);
        AutoStrategyRhV3(payable(pkg.strategy)).transferOwnershipFromFactory(newOwner);
        ShareStakingRhV3(pkg.shareStaking).transferOwnershipFromFactory(newOwner);

        emit PackageOwnershipTransferred(asset, vaultOwner, newOwner);
    }

    function _validateInfra(InfraConfig memory config) private pure {
        if (
            config.swapRouter == address(0) || config.operatorRegistry == address(0) || config.keeper == address(0)
                || config.feeManager == address(0)
        ) revert ZeroAddress();
    }
}
