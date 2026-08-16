// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/LiquidityLibraryV4.sol";
import "./V4Deployments4663.sol";
import "./AutoStrategyV2.sol";
import "./AutoVaultV2.sol";
import "./LiquidShares.sol";
import "./ShareStaking.sol";
import "./interfaces/IAutoSwapRouter.sol";
import "./interfaces/IAutoKeeper.sol";
import "./interfaces/IAutoOperatorRegistry.sol";

/// @title AutoFactoryV2
/// @notice RH (4663) deploys AutoStrategyV2 + AutoVaultV2 + LiquidShares + ShareStaking packages.
contract AutoFactoryV2 is Ownable {
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
        if (!IAutoOperatorRegistry(infra.operatorRegistry).isOperator(msg.sender) && msg.sender != owner()) {
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

    constructor(InfraConfig memory config) Ownable(msg.sender) {
        _validateInfra(config);
        infra = config;
        strategyImplementation = address(new AutoStrategyV2(address(this)));
        vaultImplementation = address(new AutoVaultV2());
        liquidSharesImplementation = address(new LiquidShares());
        shareStakingImplementation = address(new ShareStaking());
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

    /// @notice Deploy package against a manual ASSET/aeWETH PoolKey (not native ETH address(0)).
    function deployVaultPackage(address asset, LiquidityLibraryV4.PoolKey calldata key, bytes calldata hookData)
        external
        onlyOperator
        returns (address strategy, address vault, address liquidShares, address shareStaking, uint256 keeperId)
    {
        if (asset == address(0)) revert ZeroAddress();
        if (registry[asset].strategy != address(0)) revert AlreadyDeployed();

        address weth = V4Deployments4663.WETH;
        if (key.currency0 == address(0) || key.currency1 == address(0)) revert InvalidPoolKey();
        if (
            !((key.currency0 == asset && key.currency1 == weth)
                || (key.currency1 == asset && key.currency0 == weth))
        ) revert InvalidPoolKey();

        strategy = strategyImplementation.clone();
        vault = vaultImplementation.clone();
        liquidShares = liquidSharesImplementation.clone();
        shareStaking = shareStakingImplementation.clone();

        LiquidShares(liquidShares).bootstrap(vault);
        ShareStaking(shareStaking).bootstrap(
            msg.sender, liquidShares, strategy, asset, infra.swapRouter, key, hookData
        );
        AutoVaultV2(payable(vault)).bootstrap(msg.sender, strategy, liquidShares, shareStaking, asset);
        AutoStrategyV2(payable(strategy)).bootstrap(
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

        IAutoSwapRouter(infra.swapRouter).addAuthorizedStrategy(strategy);
        IAutoSwapRouter(infra.swapRouter).addAuthorizedStrategy(shareStaking);
        keeperId = IAutoKeeper(infra.keeper).addStrategy(strategy);

        registry[asset] = VaultRegistry(strategy, vault, liquidShares, shareStaking, true);
        assets.push(asset);

        emit VaultRegistryDeployed(strategy, vault, liquidShares, shareStaking, asset, msg.sender, keeperId);
        emit VaultRegistryUpdated(asset, strategy, vault, true);
    }

    /// @notice One-shot transfer of package admin ownership (vault + strategy + ShareStaking) to `newOwner`.
    function transferPackageOwnership(address asset, address newOwner) external {
        if (asset == address(0) || newOwner == address(0)) revert ZeroAddress();
        VaultRegistry memory pkg = registry[asset];
        if (pkg.strategy == address(0) || pkg.vault == address(0) || pkg.shareStaking == address(0)) {
            revert UnknownPackage();
        }

        if (
            AutoVaultV2(payable(pkg.vault)).ownershipLocked()
                || AutoStrategyV2(payable(pkg.strategy)).ownershipLocked()
                || ShareStaking(pkg.shareStaking).ownershipLocked()
        ) revert PackageOwnershipLocked();

        address vaultOwner = AutoVaultV2(payable(pkg.vault)).owner();
        address strategyOwner = AutoStrategyV2(payable(pkg.strategy)).owner();
        address stakingOwner = ShareStaking(pkg.shareStaking).owner();
        if (vaultOwner != strategyOwner || strategyOwner != stakingOwner) revert OwnerMismatch();

        if (msg.sender != vaultOwner && msg.sender != owner()) revert Unauthorized();

        AutoVaultV2(payable(pkg.vault)).transferOwnershipFromFactory(newOwner);
        AutoStrategyV2(payable(pkg.strategy)).transferOwnershipFromFactory(newOwner);
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
