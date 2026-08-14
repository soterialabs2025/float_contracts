// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/LiquidityLibraryV4.sol";
import "./V4Deployments4663.sol";
import "./AutoStrategyV2.sol";
import "./AutoVaultV2.sol";
import "./AutoLiquidToken.sol";
import "./interfaces/IAutoSwapRouter.sol";
import "./interfaces/IAutoKeeper.sol";
import "./interfaces/IAutoOperatorRegistry.sol";

/// @title AutoFactoryV2
/// @notice RH (4663) deploys AutoStrategyV2 + AutoVaultV2 + AutoLiquidToken packages (dual-bucket reserve).
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
        bool active;
    }

    InfraConfig public infra;
    address public immutable strategyImplementation;
    address public immutable vaultImplementation;
    address public immutable liquidTokenImplementation;

    mapping(address => VaultRegistry) public registry;
    address[] public assets;

    error ZeroAddress();
    error InvalidPoolKey();
    error AlreadyDeployed();
    error Unauthorized();

    modifier onlyOperator() {
        if (
            !IAutoOperatorRegistry(infra.operatorRegistry).isOperator(msg.sender) && msg.sender != owner()
        ) revert Unauthorized();
        _;
    }

    event VaultRegistryDeployed(
        address indexed strategy,
        address indexed vault,
        address indexed liquidToken,
        address asset,
        address owner,
        uint256 keeperId
    );
    event VaultRegistryUpdated(address indexed asset, address strategy, address vault, bool active);

    constructor(InfraConfig memory config) Ownable(msg.sender) {
        if (
            config.swapRouter == address(0) || config.operatorRegistry == address(0) || config.keeper == address(0)
                || config.feeManager == address(0)
        ) {
            revert ZeroAddress();
        }
        infra = config;
        strategyImplementation = address(new AutoStrategyV2(address(this)));
        vaultImplementation = address(new AutoVaultV2());
        liquidTokenImplementation = address(new AutoLiquidToken());
    }

    function updateInfra(InfraConfig calldata config) external onlyOwner {
        if (
            config.swapRouter == address(0) || config.operatorRegistry == address(0) || config.keeper == address(0)
                || config.feeManager == address(0)
        ) {
            revert ZeroAddress();
        }
        infra = config;
    }

    function assetsLength() external view returns (uint256) {
        return assets.length;
    }

    function setPackage(address asset, address strategy, address vault, bool active) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        VaultRegistry storage pkg = registry[asset];
        if (pkg.strategy == address(0) && strategy != address(0)) {
            assets.push(asset);
        }
        pkg.strategy = strategy;
        pkg.vault = vault;
        pkg.active = active;
        emit VaultRegistryUpdated(asset, strategy, vault, active);
    }

    function deployVaultPackage(
        address asset,
        LiquidityLibraryV4.PoolKey calldata key,
        bytes calldata hookData
    ) external onlyOperator returns (address strategy, address vault, address liquidToken, uint256 keeperId) {
        if (asset == address(0)) revert ZeroAddress();
        if (registry[asset].strategy != address(0)) revert AlreadyDeployed();

        address weth = V4Deployments4663.WETH;
        if (
            !((key.currency0 == asset && key.currency1 == weth)
                || (key.currency1 == asset && key.currency0 == weth))
        ) revert InvalidPoolKey();

        strategy = strategyImplementation.clone();
        vault = vaultImplementation.clone();
        liquidToken = liquidTokenImplementation.clone();

        AutoLiquidToken(liquidToken).bootstrap(vault);
        AutoVaultV2(payable(vault)).bootstrap(msg.sender, strategy, liquidToken, asset);
        AutoStrategyV2(payable(strategy)).bootstrap(
            msg.sender,
            vault,
            infra.swapRouter,
            infra.operatorRegistry,
            infra.keeper,
            infra.feeManager,
            asset,
            key,
            hookData
        );

        IAutoSwapRouter(infra.swapRouter).addAuthorizedStrategy(strategy);
        keeperId = IAutoKeeper(infra.keeper).addStrategy(strategy);

        registry[asset] = VaultRegistry({strategy: strategy, vault: vault, active: true});
        assets.push(asset);

        emit VaultRegistryDeployed(strategy, vault, liquidToken, asset, msg.sender, keeperId);
        emit VaultRegistryUpdated(asset, strategy, vault, true);
    }
}
