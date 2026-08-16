// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./V3Deployments8453.sol";
import "./AutoStrategyV3.sol";
import "./AutoVaultV3.sol";
import "./LiquidShares.sol";
import "./ShareStaking.sol";
import "./interfaces/IAutoSwapRouterV3.sol";
import "./interfaces/IAutoKeeper.sol";
import "./interfaces/IAutoOperatorRegistry.sol";
import "./interfaces/IUniswapV3Factory.sol";

contract AutoFactoryV3 is Ownable {
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
    address public immutable shareStakingImplementation;
    mapping(address => VaultRegistry) public registry;
    address[] public assets;

    error ZeroAddress();
    error InvalidPool();
    error AlreadyDeployed();
    error Unauthorized();
    error OwnerMismatch();
    error UnknownPackage();
    error PackageOwnershipLocked();

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

    constructor(InfraConfig memory config) Ownable(msg.sender) {
        _validateInfra(config);
        infra = config;
        strategyImplementation = address(new AutoStrategyV3(address(this)));
        vaultImplementation = address(new AutoVaultV3());
        liquidSharesImplementation = address(new LiquidShares());
        shareStakingImplementation = address(new ShareStaking());
    }

    modifier onlyOperator() {
        if (!IAutoOperatorRegistry(infra.operatorRegistry).isOperator(msg.sender) && msg.sender != owner()) {
            revert Unauthorized();
        }
        _;
    }

    function updateInfra(InfraConfig calldata config) external onlyOwner {
        _validateInfra(config);
        infra = config;
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
        returns (address strategy, address vault, address liquidShares, address shareStaking, uint256 keeperId)
    {
        if (asset == address(0)) revert ZeroAddress();
        if (registry[asset].strategy != address(0)) revert AlreadyDeployed();
        if (IUniswapV3Factory(V3Deployments8453.FACTORY).getPool(asset, V3Deployments8453.WETH, poolFee) == address(0))
        {
            revert InvalidPool();
        }

        strategy = strategyImplementation.clone();
        vault = vaultImplementation.clone();
        liquidShares = liquidSharesImplementation.clone();
        shareStaking = shareStakingImplementation.clone();

        LiquidShares(liquidShares).bootstrap(vault);
        ShareStaking(shareStaking).bootstrap(
            msg.sender, liquidShares, strategy, asset, infra.swapRouter, poolFee
        );
        AutoVaultV3(payable(vault)).bootstrap(msg.sender, strategy, liquidShares, shareStaking, asset);
        AutoStrategyV3(payable(strategy)).bootstrap(
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

        IAutoSwapRouterV3(infra.swapRouter).addAuthorizedStrategy(strategy);
        // ShareStaking swaps ASSET→WETH for epoch rewards via the same router whitelist.
        IAutoSwapRouterV3(infra.swapRouter).addAuthorizedStrategy(shareStaking);
        keeperId = IAutoKeeper(infra.keeper).addStrategy(strategy);

        registry[asset] = VaultRegistry(strategy, vault, liquidShares, shareStaking, poolFee, true);
        assets.push(asset);
        emit VaultRegistryDeployed(
            strategy, vault, liquidShares, shareStaking, asset, poolFee, msg.sender, keeperId
        );
        emit VaultRegistryUpdated(asset, strategy, vault, true);
    }

    /// @notice One-shot transfer of package admin ownership (vault + strategy + ShareStaking) to `newOwner`.
    /// @dev After this call, ownership is locked on those contracts (NFT/TBA control stays with whoever holds the NFT).
    ///      Caller must be the current owner of all three (or the factory owner). Does not move LiquidShares.
    function transferPackageOwnership(address asset, address newOwner) external {
        if (asset == address(0) || newOwner == address(0)) revert ZeroAddress();
        VaultRegistry memory pkg = registry[asset];
        if (pkg.strategy == address(0) || pkg.vault == address(0) || pkg.shareStaking == address(0)) {
            revert UnknownPackage();
        }

        if (
            AutoVaultV3(payable(pkg.vault)).ownershipLocked()
                || AutoStrategyV3(payable(pkg.strategy)).ownershipLocked()
                || ShareStaking(pkg.shareStaking).ownershipLocked()
        ) revert PackageOwnershipLocked();

        address vaultOwner = AutoVaultV3(payable(pkg.vault)).owner();
        address strategyOwner = AutoStrategyV3(payable(pkg.strategy)).owner();
        address stakingOwner = ShareStaking(pkg.shareStaking).owner();
        if (vaultOwner != strategyOwner || strategyOwner != stakingOwner) revert OwnerMismatch();

        if (msg.sender != vaultOwner && msg.sender != owner()) revert Unauthorized();

        AutoVaultV3(payable(pkg.vault)).transferOwnershipFromFactory(newOwner);
        AutoStrategyV3(payable(pkg.strategy)).transferOwnershipFromFactory(newOwner);
        ShareStaking(pkg.shareStaking).transferOwnershipFromFactory(newOwner);

        emit PackageOwnershipTransferred(asset, vaultOwner, newOwner);
    }

    function _validateInfra(InfraConfig memory config) private pure {
        if (
            config.swapRouter == address(0) || config.operatorRegistry == address(0) || config.keeper == address(0)
                || config.feeManager == address(0)
        ) revert ZeroAddress();
    }
}
