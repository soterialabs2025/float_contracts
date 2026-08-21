// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/ILiquidStrategyV4.sol";
import "./interfaces/ILiquidTokenVault.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LiquidVaultV4
/// @notice WETH-only deposit vault for the liquid v4 minimal strategy stack.
/// @dev    Mints `LiquidTokenV4` shares pro-rata against `strategy.vaultValue()`, then forwards WETH
///         to the strategy. No in-vault token swaps — users must supply WETH (approve + `depositWeth`).
contract LiquidVaultV4 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public weth;
    ILiquidStrategyV4 public strategy;
    ILiquidTokenVault public liquidToken;

    address public liquidTokenAddress;
    address public strategyAddr;
    address private constant WETH_ADDR = 0x4200000000000000000000000000000000000006;

    bool public contractSetUp;
    bool public retired;
    bool public retireWithdrawalPaused = true;
    uint256 public retiredPoolValue;
    uint256 public retiredWethBalance;
    uint256 public retiredTotalSupply;

    event ContractSetUp(address indexed caller);
    event TokenRescued(address indexed token, address indexed recipient, uint256 amount);
    event Deposit(address indexed depositor, uint256 amount, uint256 shares);
    event StrategyRetired(uint256 vaultValue);
    event RetireWithdrawal(address indexed receiver, uint256 shares, uint256 tokenAmount, uint256 wethAmount);

    constructor() Ownable(_msgSender()) {}

    /// @param _strategyAddr Minimal liquid strategy (`LiquidStratMinV4`).
    /// @param _liquidTokenAddr Share token (`LiquidTokenV4`) with this vault as minter/burner.
    function setUpContract(address _strategyAddr, address _liquidTokenAddr) external onlyOwner {
        require(_strategyAddr != address(0), "strategy=0");
        require(_liquidTokenAddr != address(0), "liquidToken=0");

        strategyAddr = _strategyAddr;
        liquidTokenAddress = _liquidTokenAddr;
        strategy = ILiquidStrategyV4(_strategyAddr);
        liquidToken = ILiquidTokenVault(_liquidTokenAddr);
        weth = IERC20(WETH_ADDR);
        contractSetUp = true;
        emit ContractSetUp(_msgSender());
    }

    function balance() public view returns (uint256) {
        if (address(strategy) == address(0)) return 0;
        return strategy.vaultValue();
    }

    function totalSupply() public view returns (uint256) {
        return liquidToken.totalSupply();
    }

    function available() public view returns (uint256) {
        return address(weth) != address(0) ? weth.balanceOf(address(this)) : 0;
    }

    function getPricePerFullShare() public view returns (uint256) {
        uint256 supply = liquidToken.totalSupply();
        return supply == 0 ? 1e18 : balance() * 1e18 / supply;
    }

    function _earn(uint256 wethAmount) internal {
        if (wethAmount > 0 && address(strategy) != address(0)) {
            weth.safeTransfer(address(strategy), wethAmount);
            strategy.deposit(wethAmount);
        }
    }

    /// @notice Deposit WETH and mint `LiquidTokenV4` shares pro-rata against current vault NAV.
    /// @dev    Caller must `WETH.approve(vault, amount)` first.
    function depositWeth(uint256 amount) external nonReentrant returns (uint256 shares) {
        return _depositWeth(amount);
    }

    function _depositWeth(uint256 amount) internal returns (uint256 shares) {
        require(!retired, "Strategy retired");
        require(contractSetUp, "not initialized");
        require(address(liquidToken) != address(0), "liquidToken not set");
        require(address(weth) != address(0), "weth not set");
        require(amount > 0, "zero");

        address depositor = _msgSender();
        uint256 supply = totalSupply();
        uint256 navBefore = 0;

        if (address(strategy) != address(0)) {
            strategy.beforeDeposit();
            navBefore = strategy.vaultValue();
        }

        uint256 balBefore = weth.balanceOf(address(this));
        weth.safeTransferFrom(depositor, address(this), amount);
        uint256 received = weth.balanceOf(address(this)) - balBefore;
        require(received > 0, "no WETH received");

        _earn(received);

        if (supply == 0 || navBefore == 0) {
            shares = received;
        } else {
            shares = Math.mulDiv(received, supply, navBefore);
        }
        require(shares > 0, "zero shares");

        liquidToken.mint(depositor, shares);
        emit Deposit(depositor, received, shares);
    }

    /// @notice Re-deposit WETH held by the vault into the strategy after `retireStrategy()`.
    function depositRetiredTokens() external onlyOwner nonReentrant {
        require(retired, "Strategy not retired");
        require(address(strategy) != address(0), "No strategy set");
        require(retiredWethBalance > 0, "No WETH to re-deposit");
        require(retiredTotalSupply > 0, "Invalid retired total supply");
        require(retiredPoolValue > 0, "Invalid retired pool value");

        uint256 vaultWethBal = weth.balanceOf(address(this));
        require(vaultWethBal >= retiredWethBalance, "Insufficient WETH in vault");

        uint256 wethToDeposit = retiredWethBalance;

        strategy.beforeDeposit();
        uint256 poolValueBefore = strategy.vaultValue();

        weth.safeTransfer(address(strategy), wethToDeposit);
        strategy.deposit(wethToDeposit);

        uint256 poolValueAfter = strategy.vaultValue();
        require(poolValueAfter > poolValueBefore, "No pool value increase after deposit");

        retired = false;
        retiredWethBalance = 0;
        retiredPoolValue = 0;
        retiredTotalSupply = 0;

        emit Deposit(address(this), wethToDeposit, 0);
    }

    /// @notice Withdraw shares; strategy sends WETH to `msg.sender`.
    function withdraw(uint256 shares) external nonReentrant returns (uint256 assets) {
        require(!retired, "Strategy retired - use retireWithdrawal()");
        require(shares > 0, "zero");

        address receiver = _msgSender();
        require(shares <= liquidToken.balanceOf(receiver), "Insufficient shares");

        uint256 totalSupply_ = liquidToken.totalSupply();
        require(totalSupply_ > 0, "No supply");
        require(liquidToken.allowance(receiver, address(this)) >= shares, "Vault not approved");

        liquidToken.transferFrom(receiver, address(this), shares);

        uint256 balBefore = balance();
        strategy.withdraw(shares, totalSupply_, receiver);
        liquidToken.burn(address(this), shares);

        assets = Math.mulDiv(balBefore, shares, totalSupply_);
    }

    function getIdleBalance() external view returns (uint256) {
        if (address(strategy) == address(0)) return 0;
        return strategy.vaultValue();
    }

    function getPoolBalance() external view returns (uint256 tokenAmt, uint256 wethAmt) {
        if (address(strategy) == address(0)) return (0, 0);
        address asset = strategy.assetAddr();
        tokenAmt = asset == address(0) ? 0 : IERC20(asset).balanceOf(address(strategy));
        wethAmt = weth.balanceOf(address(strategy));
    }

    /// @notice Drain strategy to WETH in this vault for emergency exit.
    function retireStrategy() external onlyOwner nonReentrant {
        require(!retired, "Strategy already retired");
        require(address(strategy) != address(0), "No strategy set");

        uint256 totalSupply_ = liquidToken.totalSupply();
        require(totalSupply_ > 0, "No shares outstanding");

        retiredPoolValue = strategy.vaultValue();
        require(retiredPoolValue > 0, "No pool value to retire");

        retiredTotalSupply = totalSupply_;

        uint256 wethBefore = weth.balanceOf(address(this));
        strategy.withdraw(totalSupply_, totalSupply_, address(this));
        retiredWethBalance = weth.balanceOf(address(this)) - wethBefore;

        retired = true;
        emit StrategyRetired(retiredPoolValue);
    }

    function changeAsset(address _newAssetAddr) external onlyOwner nonReentrant {
        require(address(strategy) != address(0), "No strategy set");
        strategy.changeAsset(_newAssetAddr);
    }

    function retireWithdrawal(uint256 shares) external nonReentrant returns (uint256 wethAmount) {
        require(!retireWithdrawalPaused, "Retire withdrawal paused");
        require(retired, "Strategy not retired");
        require(shares > 0, "zero shares");
        require(retiredTotalSupply > 0, "Invalid retired total supply");

        address receiver = _msgSender();
        require(shares <= liquidToken.balanceOf(receiver), "Insufficient shares");
        require(liquidToken.allowance(receiver, address(this)) >= shares, "Vault not approved");

        liquidToken.transferFrom(receiver, address(this), shares);

        wethAmount = Math.mulDiv(retiredWethBalance, shares, retiredTotalSupply);

        uint256 vaultWethBal = weth.balanceOf(address(this));
        if (wethAmount > vaultWethBal) wethAmount = vaultWethBal;

        retiredWethBalance -= wethAmount;

        if (wethAmount > 0) {
            weth.safeTransfer(receiver, wethAmount);
        }

        liquidToken.burn(address(this), shares);

        emit RetireWithdrawal(receiver, shares, 0, wethAmount);
    }

    function hasApproval(address owner, uint256 amount) external view returns (bool) {
        return liquidToken.allowance(owner, address(this)) >= amount;
    }

    function getVaultAddress() external view returns (address) {
        return address(this);
    }

    function getApproval(address owner) external view returns (uint256) {
        return liquidToken.allowance(owner, address(this));
    }

    function rescueToken(address _token, address _recipient) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        require(_recipient != address(0), "Invalid recipient address");

        uint256 amount = IERC20(_token).balanceOf(address(this));
        require(amount > 0, "No tokens to rescue");

        IERC20(_token).safeTransfer(_recipient, amount);
        emit TokenRescued(_token, _recipient, amount);
    }

    function unpauseRetireWithdrawal() external onlyOwner {
        retireWithdrawalPaused = false;
    }

    function pauseRetireWithdrawal() external onlyOwner {
        retireWithdrawalPaused = true;
    }
}
