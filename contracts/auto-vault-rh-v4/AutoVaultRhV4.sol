// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IAutoVaultRhV4.sol";
import "./interfaces/IAutoStrategyRhV4.sol";
import "./interfaces/ILiquidSharesRhV4.sol";

/// @title AutoVaultRhV4
/// @notice RH (4663) AutoVault: ETH-only deposits into token/native-ETH v4 packages.
contract AutoVaultRhV4 is Ownable, ReentrancyGuard, Pausable, IAutoVaultRhV4 {
    IAutoStrategyRhV4 public strategy;
    ILiquidSharesRhV4 public liquidShares;
    address public shareStaking;
    IERC20 public asset;
    address public factory;
    bool public bootstrapped;
    /// @notice After one factory ownership transfer (e.g. to ERC-6551), ownership cannot move again.
    bool public ownershipLocked;
    PoolValueSnapshot[] private _poolValueSnapshots;

    event Deposit(address indexed user, uint256 ethNotional, uint256 shares);
    event Withdraw(address indexed user, uint256 shares, bool asAsset, uint256 outAmount);
    event PoolValueSnapshotRecorded(uint256 valueWeth, uint256 uniswapFeesCollected, uint64 timestamp);
    event OwnershipLocked(address indexed owner);

    error Unauthorized();
    error ZeroAddress();
    error ZeroValue();
    error AlreadyBootstrapped();
    error NotBootstrapped();
    error OwnershipIsLocked();

    constructor() Ownable(msg.sender) {}

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
        strategy = IAutoStrategyRhV4(strategy_);
        liquidShares = ILiquidSharesRhV4(liquidShares_);
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
        if (!bootstrapped) revert NotBootstrapped();
        uint256 navBefore = balance();
        strategy.deposit{value: msg.value}();
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
        IAutoStrategyRhV4.WithdrawToken out =
            asAsset ? IAutoStrategyRhV4.WithdrawToken.ASSET : IAutoStrategyRhV4.WithdrawToken.WETH;
        uint256 beforeBal = asAsset ? asset.balanceOf(msg.sender) : msg.sender.balance;
        strategy.withdraw(shares, msg.sender, out);
        liquidShares.burn(msg.sender, shares);
        uint256 afterBal = asAsset ? asset.balanceOf(msg.sender) : msg.sender.balance;
        uint256 received = afterBal > beforeBal ? afterBal - beforeBal : 0;
        emit Withdraw(msg.sender, shares, asAsset, received);
        return received;
    }

    receive() external payable {
        revert ZeroValue();
    }
}
