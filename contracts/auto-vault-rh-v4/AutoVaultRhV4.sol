// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IAutoVaultRhV4.sol";
import "./interfaces/IAutoStrategyRhV4.sol";
import "./interfaces/ILiquidSharesRhV4.sol";

/// @title AutoVaultRhV4
/// @notice RH (4663) AutoVault: ETH-only deposits into token/native-ETH v4 packages.
contract AutoVaultRhV4 is Ownable, ReentrancyGuard, IAutoVaultRhV4 {
    IAutoStrategyRhV4 public strategy;
    ILiquidSharesRhV4 public liquidShares;
    address public shareStaking;
    IERC20 public asset;
    address public immutable factory;
    bool public bootstrapped;
    /// @notice After one factory ownership transfer (e.g. to ERC-6551), ownership cannot move again.
    bool public ownershipLocked;
    uint256 public accUniswapFeesPerShare;
    uint256 public uniswapFeesCollectedSynced;
    /// @dev Near-full withdraw sweeps leftover shares below this, so wei dust cannot keep a vault from emptying.
    uint256 internal constant MIN_SHARE_DUST = 1e10;
    /// @dev OZ-style virtual offset so a dust seed + donation cannot floor a later mint to 1 share.
    uint256 internal constant VIRTUAL_SHARES = 1e3;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    event Deposit(address indexed user, uint256 ethNotional, uint256 shares, uint256 acc);
    event Withdraw(address indexed user, uint256 shares, bool indexed asAsset, uint256 outAmount, uint256 acc);
    event PoolValueSnapshotRecorded(uint256 valueWeth, uint256 uniswapFeesCollected, uint64 indexed timestamp);
    event OwnershipLocked(address indexed owner);

    error Unauthorized();
    error ZeroAddress();
    error ZeroValue();
    error AlreadyBootstrapped();
    error NotBootstrapped();
    error OwnershipIsLocked();
    error RefUnavailable();

    /// @notice Implementation sets immutable `factory` (copied into EIP-1167 clones).
    constructor(address factory_) Ownable(msg.sender) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
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
        if (ownershipLocked) revert OwnershipIsLocked();
        if (msg.sender != factory) revert Unauthorized();
        if (
            owner_ == address(0) || strategy_ == address(0) || liquidShares_ == address(0)
                || shareStaking_ == address(0) || asset_ == address(0)
        ) {
            revert ZeroAddress();
        }
        strategy = IAutoStrategyRhV4(strategy_);
        liquidShares = ILiquidSharesRhV4(liquidShares_);
        shareStaking = shareStaking_;
        asset = IERC20(asset_);
        bootstrapped = true;
        uniswapFeesCollectedSynced = strategy.UniswapFeesCollected();
        _transferOwnership(owner_);
    }

    /// @notice One-shot factory ownership move (e.g. package → ERC-6551 TBA). Locks ownership afterward.
    function transferOwnershipFromFactory(address newOwner) external {
        if (msg.sender != factory) revert Unauthorized();
        if (!bootstrapped) revert NotBootstrapped();
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
        if (!bootstrapped) revert NotBootstrapped();
        uint256 supply = totalSupply();
        if (supply == 0 && msg.sender != owner()) revert Unauthorized();

        // Collect fees before pricing so they accrue to the pre-mint supply.
        strategy.syncFees();
        uint256 navBefore = balance();
        // Later mints: gated reference (same swap-gate band as remint). After `strategy.deposit` the reference includes `msg.value`.
        uint256 navRef;
        if (supply != 0) {
            navRef = strategy.poolValueRef();
            if (navRef == 0) revert RefUnavailable();
        }
        strategy.deposit{value: msg.value}();
        uint256 navAfter = balance();
        uint256 credited = navAfter > navBefore ? navAfter - navBefore : 0;
        // Cap to deposited ETH so spot/NAV jumps between reads cannot overmint shares (V-NAV-MINT).
        if (credited > msg.value) credited = msg.value;
        shares = _sharesForDeposit(credited, navBefore, supply, navRef);
        if (shares == 0) revert ZeroValue();
        _syncAcc();
        liquidShares.mint(msg.sender, shares);
        emit Deposit(msg.sender, credited, shares, accUniswapFeesPerShare);
    }

    /// @dev Owner seeds 1:1. Later min(spot, gated reference). `navRef` is pre-deposit, or 0 if unseeded.
    function _sharesForDeposit(uint256 credited, uint256 navBefore, uint256 supply, uint256 navRef)
        internal
        pure
        returns (uint256)
    {
        if (supply == 0) return credited;
        uint256 sharesSpot = navBefore == 0
            ? type(uint256).max
            : Math.mulDiv(credited, supply + VIRTUAL_SHARES, navBefore + VIRTUAL_ASSETS);
        if (navRef == 0) return sharesSpot;
        return Math.min(sharesSpot, Math.mulDiv(credited, supply + VIRTUAL_SHARES, navRef + VIRTUAL_ASSETS));
    }

    function withdraw(uint256 shares, bool asAsset) external override nonReentrant returns (uint256) {
        uint256 supply = totalSupply();
        uint256 bal = balanceOf(msg.sender);
        if (shares == 0 || supply == 0) revert ZeroValue();
        // Clamp rather than revert. A caller sizing shares from a supply or NAV that has since moved overshoots its
        // own balance, and reverting gives it no way to tell that apart from an empty vault: estimation just fails
        // and no transaction is produced. Nobody can withdraw more than they hold either way.
        if (shares > bal) shares = bal;
        // Treat near-full personal exits as full exits so wei dust is not left behind.
        if (bal - shares < MIN_SHARE_DUST) shares = bal;
        IAutoStrategyRhV4.WithdrawToken out =
            asAsset ? IAutoStrategyRhV4.WithdrawToken.ASSET : IAutoStrategyRhV4.WithdrawToken.WETH;
        _syncAcc();
        uint256 beforeBal = asAsset ? asset.balanceOf(msg.sender) : msg.sender.balance;
        strategy.withdraw(shares, msg.sender, out);
        liquidShares.burn(msg.sender, shares);
        uint256 afterBal = asAsset ? asset.balanceOf(msg.sender) : msg.sender.balance;
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
