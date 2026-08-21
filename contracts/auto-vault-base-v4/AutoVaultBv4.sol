// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "../v4/V4Deployments8453.sol";
import "./interfaces/IAutoVaultBv4.sol";
import "./interfaces/IAutoStrategyBv4.sol";
import "./interfaces/ILiquidSharesBv4.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

/// @title AutoVaultBv4
/// @notice Base (8453) AutoVault: ETH-only deposits, LiquidSharesBv4 + ShareStakingBv4 package, ownership lock.
contract AutoVaultBv4 is Ownable, ReentrancyGuard, Pausable, IAutoVaultBv4 {
    using SafeERC20 for IERC20;

    IWETH public immutable weth;
    IAutoStrategyBv4 public strategy;
    ILiquidSharesBv4 public liquidShares;
    address public shareStaking;
    IERC20 public asset;
    address public factory;
    bool public bootstrapped;
    /// @notice After one factory ownership transfer (e.g. to ERC-6551), ownership cannot move again.
    bool public ownershipLocked;
    PoolValueSnapshot[] private _poolValueSnapshots;

    event Deposit(address indexed user, uint256 wethNotional, uint256 shares);
    event Withdraw(address indexed user, uint256 shares, bool asAsset, uint256 outAmount);
    event PoolValueSnapshotRecorded(uint256 valueWeth, uint256 uniswapFeesCollected, uint64 timestamp);
    event OwnershipLocked(address indexed owner);

    error Unauthorized();
    error ZeroAddress();
    error ZeroValue();
    error AlreadyBootstrapped();
    error NotBootstrapped();
    error OwnershipIsLocked();

    constructor() Ownable(msg.sender) {
        weth = IWETH(V4Deployments8453.WETH);
    }

    modifier onlyAutoKeeper() {
        if (msg.sender != strategy.keeper()) revert Unauthorized();
        _;
    }

    function bootstrap(
        address owner_,
        address strategy_,
        address liquidShares_,
        address shareStaking_,
        address asset_
    ) external {
        if (bootstrapped) revert AlreadyBootstrapped();
        if (
            owner_ == address(0) || strategy_ == address(0) || liquidShares_ == address(0)
                || shareStaking_ == address(0) || asset_ == address(0)
        ) {
            revert ZeroAddress();
        }
        factory = msg.sender;
        strategy = IAutoStrategyBv4(strategy_);
        liquidShares = ILiquidSharesBv4(liquidShares_);
        shareStaking = shareStaking_;
        asset = IERC20(asset_);
        bootstrapped = true;
        _transferOwnership(owner_);
    }

    /// @notice One-shot factory ownership move (e.g. package → ERC-6551 TBA). Locks ownership afterward.
    function transferOwnershipFromFactory(address newOwner) external {
        if (msg.sender != factory) revert Unauthorized();
        if (newOwner == address(0)) revert ZeroAddress();
        if (ownershipLocked) revert OwnershipIsLocked();
        _transferOwnership(newOwner);
        ownershipLocked = true;
        emit OwnershipLocked(newOwner);
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        if (ownershipLocked) revert OwnershipIsLocked();
        super.transferOwnership(newOwner);
    }

    function renounceOwnership() public override onlyOwner {
        if (ownershipLocked) revert OwnershipIsLocked();
        super.renounceOwnership();
    }

    function recordPoolValueSnapshot() external override onlyAutoKeeper {
        if (!bootstrapped) revert NotBootstrapped();
        uint256 pv = strategy.poolValue();
        uint256 fees = strategy.UniswapFeesCollected();
        _poolValueSnapshots.push(
            PoolValueSnapshot({valueWeth: pv, uniswapFeesCollected: fees, timestamp: uint64(block.timestamp)})
        );
        emit PoolValueSnapshotRecorded(pv, fees, uint64(block.timestamp));
    }

    function getPoolValueSnapshotCount() external view override returns (uint256) {
        return _poolValueSnapshots.length;
    }

    function poolValueSnapshots(uint256 index)
        external
        view
        override
        returns (uint256 valueWeth, uint256 uniswapFeesCollected, uint64 timestamp)
    {
        PoolValueSnapshot storage s = _poolValueSnapshots[index];
        return (s.valueWeth, s.uniswapFeesCollected, s.timestamp);
    }

    function balance() public view override returns (uint256) {
        return strategy.balance();
    }

    function balanceOf(address account) public view override returns (uint256) {
        return liquidShares.balanceOf(account);
    }

    function totalSupply() public view override returns (uint256) {
        return liquidShares.totalSupply();
    }

    function depositETH() external payable override nonReentrant whenNotPaused returns (uint256 shares) {
        if (msg.value == 0) revert ZeroValue();
        weth.deposit{value: msg.value}();
        return _mintSharesAndDeploy(msg.value);
    }

    function _mintSharesAndDeploy(uint256 amount) internal returns (uint256 shares) {
        if (!bootstrapped) revert NotBootstrapped();
        uint256 navBefore = balance();
        IERC20(address(weth)).forceApprove(address(strategy), amount);
        strategy.deposit(amount);
        uint256 navAfter = balance();
        uint256 credited = navAfter > navBefore ? navAfter - navBefore : 0;
        shares = _sharesForDeposit(credited, navBefore);
        if (shares == 0) revert ZeroValue();
        liquidShares.mint(msg.sender, shares);
        emit Deposit(msg.sender, credited, shares); 
    }

    function _sharesForDeposit(uint256 amount, uint256 navBefore) internal view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 || navBefore == 0 ? amount : Math.mulDiv(amount, supply, navBefore);
    }

    function withdraw(uint256 shares, bool asAsset) external override nonReentrant whenNotPaused returns (uint256) {
        if (shares == 0 || totalSupply() == 0 || shares > balanceOf(msg.sender)) revert ZeroValue();
        IAutoStrategyBv4.WithdrawToken out =
            asAsset ? IAutoStrategyBv4.WithdrawToken.ASSET : IAutoStrategyBv4.WithdrawToken.WETH;
        uint256 beforeBal = asAsset ? asset.balanceOf(msg.sender) : weth.balanceOf(msg.sender);
        strategy.withdraw(shares, msg.sender, out);
        liquidShares.burn(msg.sender, shares);
        uint256 afterBal = asAsset ? asset.balanceOf(msg.sender) : weth.balanceOf(msg.sender);
        uint256 received = afterBal > beforeBal ? afterBal - beforeBal : 0;
        emit Withdraw(msg.sender, shares, asAsset, received);
        return received;
    }

    receive() external payable {
        revert ZeroValue();
    }
}
