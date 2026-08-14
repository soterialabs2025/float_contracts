// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./V4Deployments4663.sol";
import "./interfaces/IAutoVault.sol";
import "./interfaces/IAutoVaultV2.sol";
import "./interfaces/IAutoStrategy.sol";
import "./interfaces/IAutoLiquidToken.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @title AutoVaultV2
/// @notice RH (4663) AutoVault with `strategyPull` so AutoStrategyV2 can park reserved tokens during LP increase.
contract AutoVaultV2 is Ownable, ReentrancyGuard, Pausable, IAutoVaultV2 {
    using SafeERC20 for IERC20;

    IWETH public immutable weth;
    IAutoStrategy public strategy;
    IAutoLiquidToken public liquidToken;
    IERC20 public asset;
    address public factory;
    bool public bootstrapped;
    bool public neutral;

    event Deposit(address indexed user, uint256 wethNotional, uint256 shares);
    event Withdraw(address indexed user, uint256 shares, bool asAsset, uint256 outAmount);
    event NeutralEntered(uint256 poolValue);
    event NeutralExited();
    event PoolValueSnapshotRecorded(uint256 valueWeth, uint256 uniswapFeesCollected, uint64 timestamp);

    PoolValueSnapshot[] private _poolValueSnapshots;

    error Unauthorized();
    error ZeroAddress();
    error ZeroValue();
    error AlreadyBootstrapped();
    error NotBootstrapped();

    constructor() Ownable(msg.sender) {
        weth = IWETH(V4Deployments4663.WETH);
    }

    modifier onlyAutoKeeper() {
        if (msg.sender != strategy.keeper()) revert Unauthorized();
        _;
    }

    function bootstrap(address owner_, address strategy_, address liquidToken_, address asset_) external {
        if (bootstrapped) revert AlreadyBootstrapped();
        if (owner_ == address(0) || strategy_ == address(0) || liquidToken_ == address(0) || asset_ == address(0)) {
            revert ZeroAddress();
        }
        factory = msg.sender;
        strategy = IAutoStrategy(strategy_);
        liquidToken = IAutoLiquidToken(liquidToken_);
        asset = IERC20(asset_);
        bootstrapped = true;
        _transferOwnership(owner_);
    }

    /// @inheritdoc IAutoVaultV2
    function strategyPull(address token, uint256 amount) external override {
        if (msg.sender != address(strategy)) revert Unauthorized();
        if (amount == 0) return;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function recordPoolValueSnapshot() external override onlyAutoKeeper {
        if (!bootstrapped) revert NotBootstrapped();
        uint256 pv = strategy.poolValue();
        uint256 fees = strategy.UniswapFeesCollected();
        _poolValueSnapshots.push(
            PoolValueSnapshot({
                valueWeth: pv,
                uniswapFeesCollected: fees,
                timestamp: uint64(block.timestamp)
            })
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
        return liquidToken.balanceOf(account);
    }

    function totalSupply() public view override returns (uint256) {
        return liquidToken.totalSupply();
    }

    function depositETH() external payable override nonReentrant whenNotPaused returns (uint256 shares) {
        if (msg.value == 0) revert ZeroValue();
        weth.deposit{value: msg.value}();
        shares = _mintSharesAndDeploy(msg.value, true);
    }

    function depositWeth(uint256 amount) external override nonReentrant whenNotPaused returns (uint256 shares) {
        if (amount == 0) revert ZeroValue();
        IERC20(address(weth)).safeTransferFrom(msg.sender, address(this), amount);
        shares = _mintSharesAndDeploy(amount, true);
    }

    function depositAsset(uint256 amount) external override nonReentrant whenNotPaused returns (uint256 shares) {
        if (amount == 0) revert ZeroValue();
        if (!bootstrapped) revert NotBootstrapped();
        uint256 navBefore = balance();
        asset.safeTransferFrom(msg.sender, address(strategy), amount);
        strategy.ingestAndDeploy();
        uint256 credited = balance() > navBefore ? balance() - navBefore : 0;
        shares = _sharesForDeposit(credited, navBefore);
        if (shares == 0) revert ZeroValue();
        liquidToken.mint(msg.sender, shares);
        emit Deposit(msg.sender, credited, shares);
    }

    function _mintSharesAndDeploy(uint256 wethAmount, bool callDeposit) internal returns (uint256 shares) {
        if (!bootstrapped) revert NotBootstrapped();
        uint256 navBefore = balance();
        if (callDeposit) {
            IERC20(address(weth)).forceApprove(address(strategy), wethAmount);
            strategy.deposit(wethAmount);
        }
        uint256 credited = balance() > navBefore ? balance() - navBefore : 0;
        shares = _sharesForDeposit(credited, navBefore);
        if (shares == 0) revert ZeroValue();
        liquidToken.mint(msg.sender, shares);
        emit Deposit(msg.sender, credited, shares);
    }

    function _sharesForDeposit(uint256 amount, uint256 navBefore) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0 || navBefore == 0) return amount;
        return Math.mulDiv(amount, supply, navBefore);
    }

    function withdraw(uint256 shares, bool asAsset) external override nonReentrant whenNotPaused returns (uint256) {
        if (shares == 0) revert ZeroValue();
        if (totalSupply() == 0) revert ZeroValue();
        if (shares > balanceOf(msg.sender)) revert ZeroValue();

        IAutoStrategy.WithdrawToken out =
            asAsset ? IAutoStrategy.WithdrawToken.ASSET : IAutoStrategy.WithdrawToken.WETH;
        uint256 beforeBal = asAsset ? asset.balanceOf(msg.sender) : weth.balanceOf(msg.sender);
        strategy.withdraw(shares, msg.sender, out);
        liquidToken.burn(msg.sender, shares);
        uint256 afterBal = asAsset ? asset.balanceOf(msg.sender) : weth.balanceOf(msg.sender);
        uint256 received = afterBal > beforeBal ? afterBal - beforeBal : 0;
        emit Withdraw(msg.sender, shares, asAsset, received);
        return received;
    }

    function enterNeutral() external override onlyOwner {
        strategy.enterNeutralFromVault();
        neutral = true;
        emit NeutralEntered(balance());
    }

    function resumeNormal() external override onlyOwner {
        strategy.resumeNormalFromVault();
        strategy.ingestAndDeploy();
        neutral = false;
        emit NeutralExited();
    }

    receive() external payable {
        revert("use depositETH");
    }
}
