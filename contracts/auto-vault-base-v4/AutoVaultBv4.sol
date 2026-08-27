// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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
contract AutoVaultBv4 is Ownable, ReentrancyGuard, IAutoVaultBv4 {
    using SafeERC20 for IERC20;

    IWETH public immutable weth;
    IAutoStrategyBv4 public strategy;
    ILiquidSharesBv4 public liquidShares;
    address public shareStaking;
    IERC20 public asset;
    address public immutable factory;
    bool public bootstrapped;
    /// @notice After one factory ownership transfer (e.g. to ERC-6551), ownership cannot move again.
    bool public ownershipLocked;
    /// @notice High-water WETH-per-share (scaled 1e18). Later mints use min(spot, this).
    uint256 public lastSharePriceX18;
    uint256 public accUniswapFeesPerShare;
    uint256 public uniswapFeesCollectedSynced;

    event Deposit(address indexed user, uint256 wethNotional, uint256 shares, uint256 acc);
    event Withdraw(address indexed user, uint256 shares, bool indexed asAsset, uint256 outAmount, uint256 acc);
    event PoolValueSnapshotRecorded(uint256 valueWeth, uint256 uniswapFeesCollected, uint64 indexed timestamp);
    event OwnershipLocked(address indexed owner);
    event SharePriceHighWater(uint256 priceX18);

    error Unauthorized();
    error ZeroAddress();
    error ZeroValue();
    error AlreadyBootstrapped();
    error NotBootstrapped();
    error OwnershipIsLocked();

    /// @notice Implementation sets immutable `factory` (copied into EIP-1167 clones).
    constructor(address factory_) Ownable(msg.sender) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
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
        if (msg.sender != factory) revert Unauthorized();
        if (
            owner_ == address(0) || strategy_ == address(0) || liquidShares_ == address(0)
                || shareStaking_ == address(0) || asset_ == address(0)
        ) {
            revert ZeroAddress();
        }
        strategy = IAutoStrategyBv4(strategy_);
        liquidShares = ILiquidSharesBv4(liquidShares_);
        shareStaking = shareStaking_;
        asset = IERC20(asset_);
        bootstrapped = true;
        uniswapFeesCollectedSynced = strategy.UniswapFeesCollected();
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

    /// @notice Emit NAV + cumulative Uniswap fees for off-chain indexing. Keeper-only.
    function recordPoolValueSnapshot() external override onlyAutoKeeper {
        if (!bootstrapped) revert NotBootstrapped();
        emit PoolValueSnapshotRecorded(
            strategy.poolValue(), strategy.UniswapFeesCollected(), uint64(block.timestamp)
        );
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

    function depositETH() external payable override nonReentrant returns (uint256 shares) {
        if (msg.value == 0) revert ZeroValue();
        weth.deposit{value: msg.value}();
        return _mintSharesAndDeploy(msg.value);
    }

    function _mintSharesAndDeploy(uint256 amount) internal returns (uint256 shares) {
        if (!bootstrapped) revert NotBootstrapped();
        uint256 supply = totalSupply();
        if (supply == 0 && msg.sender != owner()) revert Unauthorized();

        uint256 navBefore = balance();
        IERC20(address(weth)).forceApprove(address(strategy), amount);
        strategy.deposit(amount);
        uint256 navAfter = balance();
        uint256 credited = navAfter > navBefore ? navAfter - navBefore : 0;
        // Cap to deposited WETH so spot/NAV jumps between reads cannot overmint shares (V-NAV-MINT).
        if (credited > amount) credited = amount;
        shares = _sharesForDeposit(credited, navBefore, supply);
        if (shares == 0) revert ZeroValue();
        _syncAcc();
        liquidShares.mint(msg.sender, shares);
        _bumpSharePriceHighWater(balance(), totalSupply());
        emit Deposit(msg.sender, credited, shares, accUniswapFeesPerShare);
    }

    /// @dev Owner seeds 1:1. Later: min(spot NAV shares, high-water share-price shares). No TWAP on Bv4 yet.
    function _sharesForDeposit(uint256 credited, uint256 navBefore, uint256 supply)
        internal
        view
        returns (uint256)
    {
        if (supply == 0) return credited;
        uint256 sharesSpot =
            navBefore == 0 ? type(uint256).max : Math.mulDiv(credited, supply, navBefore);
        return Math.min(sharesSpot, Math.mulDiv(credited, 1e18, lastSharePriceX18));
    }

    function _bumpSharePriceHighWater(uint256 nav, uint256 supply) internal {
        if (supply == 0 || nav == 0) return;
        uint256 priceX18 = Math.mulDiv(nav, 1e18, supply);
        if (priceX18 > lastSharePriceX18) {
            lastSharePriceX18 = priceX18;
            emit SharePriceHighWater(priceX18);
        }
    }

    function withdraw(uint256 shares, bool asAsset) external override nonReentrant returns (uint256) {
        if (shares == 0 || totalSupply() == 0 || shares > balanceOf(msg.sender)) revert ZeroValue();
        IAutoStrategyBv4.WithdrawToken out =
            asAsset ? IAutoStrategyBv4.WithdrawToken.ASSET : IAutoStrategyBv4.WithdrawToken.WETH;
        _syncAcc();
        uint256 beforeBal = asAsset ? asset.balanceOf(msg.sender) : weth.balanceOf(msg.sender);
        strategy.withdraw(shares, msg.sender, out);
        liquidShares.burn(msg.sender, shares);
        uint256 afterBal = asAsset ? asset.balanceOf(msg.sender) : weth.balanceOf(msg.sender);
        uint256 received = afterBal > beforeBal ? afterBal - beforeBal : 0;
        emit Withdraw(msg.sender, shares, asAsset, received, accUniswapFeesPerShare);
        return received;
    }

    function _syncAcc() internal {
        uint256 feesNow = strategy.UniswapFeesCollected();
        uint256 supply = liquidShares.totalSupply();
        if (supply > 0 && feesNow > uniswapFeesCollectedSynced) {
            accUniswapFeesPerShare += (feesNow - uniswapFeesCollectedSynced) * 1e18 / supply;
        }
        uniswapFeesCollectedSynced = feesNow;
    }

    receive() external payable {
        revert ZeroValue();
    }
}
