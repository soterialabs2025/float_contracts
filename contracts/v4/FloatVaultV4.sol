// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IFloatV4ContractManager.sol";
import "./interfaces/IFloatStrategyV4.sol";
import "./interfaces/IFloatVaultV4.sol";
import "../../interfaces/IPositionManagerV4.sol";
import "./interfaces/IFloatLiquidTokenVault.sol";
import "./interfaces/IFloatStrategyV4Ticks.sol";
import "./V4Deployments8453.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IWETH is IERC20 {
  function deposit() external payable;
}

/// @title FloatVaultV4
/// @notice WETH / native-ETH deposit vault. Mints `FloatLiquidTokenV4` shares pro-rata against strategy NAV,
///         then forwards WETH to the strategy. Non-WETH ERC-20 inflows (and in-vault token swaps) are not supported.
/// @dev    `positionManagerV4` is the Base (8453) deployment constant from `V4Deployments8453`. Strategy
///         rebalances continue to route through `FloatSwapRouterV4` (asset-keyed strict swap), but the vault
///         itself no longer talks to the swap router.
contract FloatVaultV4 is Ownable, ReentrancyGuard, Pausable, IFloatVaultV4 {
   
  using SafeERC20 for IERC20;

  IERC20 public asset;
  IERC20 public weth;
  IFloatStrategyV4 public strategy;
  IFloatLiquidTokenVault public liquidToken;
  IFloatV4ContractManager public immutable _manager;

  /// @notice Uniswap v4 PositionManager (for `getPositionDetails` liquidity); Base mainnet address from deployments doc.
  IPositionManagerV4 public immutable positionManagerV4;

  address public assetAddress;
  address public liquidTokenAddress;
  address public strategyAddr;
  address private demeterAddr;
  address private constant WETH_ADDR = 0x4200000000000000000000000000000000000006;
  bool public contractSetUp;
  bool public neutral;
  bool public neutralWithdrawalPaused = true;
  uint256 public neutralPoolValue;
  uint256 public neutralTokenBalance;
  uint256 public neutralWethBalance;
  uint256 public neutralTotalSupply;
  
  event ContractSetUp(address indexed caller);
  event TokenRescued(address indexed token, address indexed recipient, uint256 amount);
  event Deposit(address indexed depositor, uint256 amount, uint256 shares);
  event StrategyNeutral(uint256 poolValue);
  event NeutralWithdrawal(address indexed receiver, uint256 shares, uint256 tokenAmount, uint256 wethAmount);
  event AssetChanged(address indexed newAsset);
  event PoolValueSnapshotRecorded(uint256 valueWeth, uint256 uniswapFeesCollected, uint64 timestamp);

  /// @dev Scaled accumulator for `UniswapFeesCollected` growth per liquid share (WETH-notional attribution, not a claim).
  uint256 public constant FEES_PER_SHARE_PRECISION = 1e18;
  uint256 public accUniswapFeesPerShare;
  /// @notice Last `strategy.UniswapFeesCollected()` value applied into `accUniswapFeesPerShare`.
  uint256 public uniswapFeesCollectedSynced;
  mapping(address => uint256) public uniswapFeeDebt;

  /// @notice WETH-denominated Uniswap position value + cumulative fees at snapshot time.
  struct PoolValueSnapshot {
    uint256 valueWeth;
    uint256 uniswapFeesCollected;
    uint64 timestamp;
  }

  /// @dev Index `0` is oldest recorded in this deployment; newest is `poolValueSnapshots.length - 1`.
  PoolValueSnapshot[] public poolValueSnapshots;
  constructor(address _managerAddr) Ownable(_msgSender()) {
   require(_managerAddr != address(0), "Invalid manager address"); 
    _manager = IFloatV4ContractManager(_managerAddr);
    positionManagerV4 = IPositionManagerV4(V4Deployments8453.POSITION_MANAGER);
    contractSetUp = false;
  } 

  function setUpContract() external onlyOwner  {
    assetAddress = _manager.getAddress("ASSET");
    liquidTokenAddress = _manager.getAddress("FloatLiquidTokenV4");
    strategyAddr = _manager.getAddress("FloatStrategyV4");
    demeterAddr = _manager.getAddress("Demeter");
    strategy = IFloatStrategyV4(strategyAddr);
    asset = IERC20(assetAddress);
    weth = IERC20(WETH_ADDR);
    liquidToken = IFloatLiquidTokenVault(liquidTokenAddress);
    contractSetUp = true;
    emit ContractSetUp(_msgSender());
  }
  
  error Unauthorized();

  modifier onlyAuthorized() {
    address s = _msgSender();
    if (s != address(_manager) && s != owner() && s != demeterAddr) revert Unauthorized();
    _;
  }

  modifier onlyFloatKeeper() {
    if (_msgSender() != _manager.getAddress("FloatKeeperV4")) revert Unauthorized();
    _;
  }

  /// @notice Refresh the vault's local ASSET reference after a manager-driven rotation.
  /// @dev    Called by `FloatContractManagerV4.changeStrategyAsset` as the final step of a rotation.
  ///         Authorization (`onlyAuthorized`) covers the manager, owner, and Demeter.
  function updateAsset() external onlyAuthorized {
    assetAddress = _manager.getAddress("ASSET");
    asset = IERC20(assetAddress);
    emit AssetChanged(assetAddress);
  }

  /// @inheritdoc IFloatVaultV4
  /// @dev Callable only by `FloatKeeperV4` (per manager). Demeter triggers via `FloatKeeperV4.snapshotVaultPoolValue()`.
  function recordPoolValueSnapshot() external override onlyFloatKeeper {
    require(contractSetUp, "not initialized");
    require(address(strategy) != address(0), "no strategy");
    _syncUniswapFees();
    uint256 pv = IFloatStrategyV4(address(strategy)).poolValue();
    uint256 fees = IFloatStrategyV4(address(strategy)).UniswapFeesCollected();
    poolValueSnapshots.push(
      PoolValueSnapshot({
        valueWeth: pv,
        uniswapFeesCollected: fees,
        timestamp: uint64(block.timestamp)
      })
    );
    emit PoolValueSnapshotRecorded(pv, fees, uint64(block.timestamp));
  }

  /// @notice Number of stored pool value snapshots (newest at index `length - 1`).
  function getPoolValueSnapshotCount() external view returns (uint256) {
    return poolValueSnapshots.length;
  }

   function balance() public view returns (uint256) {
    if (address(strategy) == address(0)) return 0;
    return strategy.balanceOfIdle() + strategy.poolValue();
  }

  function totalSupply() public view returns (uint256) {
    return liquidToken.totalSupply();
  }


  /// @notice Get available WETH balance in vault (for deposits)
  /// @return Available WETH balance
  function available() public view returns (uint256) {
    return address(weth) != address(0) ? weth.balanceOf(address(this)) : 0;
  }
  
  /// @notice Get available ASSET balance in vault
  /// @return Available ASSET balance
  function availableAsset() public view returns (uint256) {
    return asset.balanceOf(address(this));
  }

  function getPricePerFullShare() public view returns (uint256) {
    return liquidToken.totalSupply() == 0 ? 1e18 : balance() * 1e18 / liquidToken.totalSupply();
  }

  /// @notice Pulls new `UniswapFeesCollected` into `accUniswapFeesPerShare` using current total supply.
  /// @dev If `totalSupply == 0`, increments are absorbed (only `uniswapFeesCollectedSynced` advances).
  function syncUniswapFees() external nonReentrant {
    _syncUniswapFees();
  }

  /// @notice WETH-notional fees attributed to this account vs `uniswapFeeDebt` (simulates pending sync).
  /// @dev Exact only when shares only change via this vault. Peer transfers of `liquidToken` desync debt.
  function pendingUniswapFees(address user) public view returns (uint256) {
    if (address(strategy) == address(0)) return 0;
    uint256 acc = accUniswapFeesPerShare;
    uint256 g = IFloatStrategyV4(address(strategy)).UniswapFeesCollected();
    uint256 last = uniswapFeesCollectedSynced;
    if (g > last) {
      uint256 delta = g - last;
      uint256 s = liquidToken.totalSupply();
      if (s > 0) {
        acc += Math.mulDiv(delta, FEES_PER_SHARE_PRECISION, s);
      }
    }
    uint256 bal = liquidToken.balanceOf(user);
    uint256 accumulated = Math.mulDiv(bal, acc, FEES_PER_SHARE_PRECISION);
    uint256 debt = uniswapFeeDebt[user];
    return accumulated > debt ? accumulated - debt : 0;
  }

  function _syncUniswapFees() internal {
    if (address(strategy) == address(0)) return;
    uint256 g = IFloatStrategyV4(address(strategy)).UniswapFeesCollected();
    if (g <= uniswapFeesCollectedSynced) return;
    uint256 delta = g - uniswapFeesCollectedSynced;
    uint256 s = liquidToken.totalSupply();
    if (s > 0) {
      accUniswapFeesPerShare += Math.mulDiv(delta, FEES_PER_SHARE_PRECISION, s);
    }
    uniswapFeesCollectedSynced = g;
  }

  function _setUniswapFeeDebt(address user) internal {
    uniswapFeeDebt[user] = Math.mulDiv(
      liquidToken.balanceOf(user),
      accUniswapFeesPerShare,
      FEES_PER_SHARE_PRECISION
    );
  }

  function _earn(uint256 wethAmount) internal {
    if (wethAmount > 0 && address(strategy) != address(0)) {
      weth.safeTransfer(address(strategy), wethAmount);
      strategy.deposit(wethAmount);
    }
  }

  /// @notice Wrap native ETH to WETH and mint shares (same accounting as `depositWeth`).
  function depositETH() external payable nonReentrant returns (uint256 shares) {
    require(msg.value > 0, "zero");
    require(address(weth) != address(0), "weth not set");
    uint256 balBefore = weth.balanceOf(address(this));
    IWETH(WETH_ADDR).deposit{value: msg.value}();
    uint256 received = weth.balanceOf(address(this)) - balBefore;
    require(received > 0, "no WETH received");
    return _depositWethAmount(_msgSender(), received);
  }

  /// @notice Deposit WETH and mint `FloatLiquidTokenV4` shares pro-rata against current vault NAV.
  /// @dev    Caller must `WETH.approve(vault, amount)` first. No in-vault token swaps.
  ///         Strategy's `beforeDeposit` is invoked before mint math so NAV is measured after any harvest.
  function depositWeth(uint256 amount) external nonReentrant returns (uint256 shares) {
    require(amount > 0, "zero");
    require(address(weth) != address(0), "weth not set");
    address depositor = _msgSender();
    uint256 balBefore = weth.balanceOf(address(this));
    weth.safeTransferFrom(depositor, address(this), amount);
    uint256 received = weth.balanceOf(address(this)) - balBefore;
    require(received > 0, "no WETH received");
    return _depositWethAmount(depositor, received);
  }

  /// @dev `received` WETH must already sit on this vault.
  function _depositWethAmount(address depositor, uint256 received) internal returns (uint256 shares) {
    require(!neutral, "Vault neutral");
    require(contractSetUp, "not initialized");
    require(address(liquidToken) != address(0), "liquidToken not set");
    require(received > 0, "zero");

    _syncUniswapFees();
    uint256 supply = totalSupply();
    uint256 poolValueBefore = address(strategy) != address(0)
      ? strategy.balanceOfIdle() + strategy.poolValue()
      : 0;

    if (address(strategy) != address(0)) {
      strategy.beforeDeposit();
      _syncUniswapFees();
      poolValueBefore = strategy.balanceOfIdle() + strategy.poolValue();
    }

    _earn(received);

    if (supply == 0 || poolValueBefore == 0) {
      shares = received;
    } else {
      shares = Math.mulDiv(received, supply, poolValueBefore);
    }
    require(shares > 0, "zero shares");

    liquidToken.mint(depositor, shares);
    _setUniswapFeeDebt(depositor);
    emit Deposit(depositor, received, shares);
  }

  /// @notice Re-deposit WETH held by the vault into the strategy after `neutralStrategy()`, then resume NORMAL mode.
  /// @dev Same economics as before: no new shares; existing holders absorb the redeployed capital via higher NAV.
  function neutralDeposit() external onlyOwner nonReentrant {
    require(neutral, "Vault not neutral");
    require(address(strategy) != address(0), "No strategy set");
    require(neutralWethBalance > 0, "No WETH to re-deposit");
    require(neutralTotalSupply > 0, "Invalid neutral total supply");
    require(neutralPoolValue > 0, "Invalid neutral pool value");

    uint256 vaultWethBal = weth.balanceOf(address(this));
    require(vaultWethBal >= neutralWethBalance, "Insufficient WETH in vault");

    uint256 wethToDeposit = neutralWethBalance;

    _syncUniswapFees();
    strategy.resumeNormalFromVault();
    strategy.beforeDeposit();
    _syncUniswapFees();
    uint256 poolValueBefore = strategy.balanceOfIdle() + strategy.poolValue();

    weth.safeTransfer(address(strategy), wethToDeposit);
    strategy.deposit(wethToDeposit);

    uint256 poolValueAfter = strategy.balanceOfIdle() + strategy.poolValue();
    require(poolValueAfter > poolValueBefore, "No pool value increase after deposit");

    neutral = false;
    neutralTokenBalance = 0;
    neutralWethBalance = 0;
    neutralPoolValue = 0;
    neutralTotalSupply = 0;

    emit Deposit(address(this), wethToDeposit, 0);
  }

  /// @notice Withdraw shares and receive WETH
  /// @param shares Number of liquidToken shares to withdraw
  /// @return assets WETH value of withdrawn shares (strategy returns WETH directly to receiver)
  function withdraw(uint256 shares) external nonReentrant returns (uint256 assets) {
    require(!neutral, "Vault neutral - use neutralWithdrawal()");
    require(shares > 0, "zero");

    _syncUniswapFees();
    address receiver = _msgSender();
    uint256 userBalance = liquidToken.balanceOf(receiver);
    require(shares <= userBalance, "Insufficient shares");
    
    uint256 totalSupply_ = liquidToken.totalSupply();
    require(totalSupply_ > 0, "No supply");
     
    require(liquidToken.allowance(receiver, address(this)) >= shares, "Vault not approved");
    liquidToken.transferFrom(receiver, address(this), shares);
    
    uint256 balBefore = balance(); // WETH-denominated value
    IFloatStrategyV4(address(strategy)).withdraw(shares, totalSupply_, receiver);
    // Collect during withdraw can bump `UniswapFeesCollected`; sync before burn while supply is unchanged.
    _syncUniswapFees();
    liquidToken.burn(address(this), shares);
    _setUniswapFeeDebt(receiver);
    
    assets = Math.mulDiv(balBefore, shares, totalSupply_); // Returns WETH value
    return assets;
  }
 

  /// @notice Check if the position is currently in range
  /// @return True if position is in range, false otherwise
  function isInRange() external view returns (bool) {
    if (address(strategy) == address(0)) return false;
    return IFloatStrategyV4(address(strategy)).readInRange();
  } 
 
  /// @notice Get the idle balance (tokens not in pool)
  /// @return The idle balance in WETH equivalent
  function getIdleBalance() external view returns (uint256) {
    if (address(strategy) == address(0)) return 0;
    return IFloatStrategyV4(address(strategy)).balanceOfIdle();
  }

  /// @notice Get the balance of tokens in the pool
  /// @return tokenAmt Amount of ASSET in pool
  /// @return wethAmt Amount of WETH in pool
  function getPoolBalance() external view returns (uint256 tokenAmt, uint256 wethAmt) {
    if (address(strategy) == address(0)) return (0, 0);
    return IFloatStrategyV4(address(strategy)).balanceOfPool();
  }
 
  /// @notice Emergency: drain strategy to WETH in this vault and set strategy mode NEUTRAL.
  /// @dev Full proportional withdraw, then `enterNeutralFromVault`. `neutralWethBalance` backs `neutralWithdrawal`.
  function neutralStrategy() external onlyOwner nonReentrant {
    require(!neutral, "Already neutral");
    require(address(strategy) != address(0), "No strategy set");

    _syncUniswapFees();
    uint256 totalSupply_ = liquidToken.totalSupply();
    require(totalSupply_ > 0, "No shares outstanding");

    neutralPoolValue = IFloatStrategyV4(address(strategy)).poolValue();
    require(neutralPoolValue > 0, "No pool value to neutralize");

    neutralTotalSupply = totalSupply_;
    neutralTokenBalance = 0;

    uint256 wethBefore = weth.balanceOf(address(this));
    strategy.withdraw(totalSupply_, totalSupply_, address(this));
    strategy.enterNeutralFromVault();
    neutralWethBalance = weth.balanceOf(address(this)) - wethBefore;
    _syncUniswapFees();

    neutral = true;
    emit StrategyNeutral(neutralPoolValue);
  }

  /// @notice Withdraw proportional WETH while the vault is neutral (after `neutralStrategy`).
  /// @dev `neutralTotalSupply` is fixed at neutralization; `neutralWethBalance` tracks remaining WETH.
  function neutralWithdrawal(uint256 shares) external nonReentrant returns (uint256 wethAmount) {
    require(!neutralWithdrawalPaused, "Neutral withdrawal paused");
    require(neutral, "Vault not neutral");
    require(shares > 0, "zero shares");
    require(neutralTotalSupply > 0, "Invalid neutral total supply");

    _syncUniswapFees();
    address receiver = _msgSender();
    require(shares <= liquidToken.balanceOf(receiver), "Insufficient shares");
    require(liquidToken.allowance(receiver, address(this)) >= shares, "Vault not approved");

    liquidToken.transferFrom(receiver, address(this), shares);

    wethAmount = Math.mulDiv(neutralWethBalance, shares, neutralTotalSupply);

    uint256 vaultWethBal = weth.balanceOf(address(this));
    if (wethAmount > vaultWethBal) wethAmount = vaultWethBal;

    neutralWethBalance -= wethAmount;

    if (wethAmount > 0) {
      weth.safeTransfer(receiver, wethAmount);
    }

    liquidToken.burn(address(this), shares);
    _syncUniswapFees();
    _setUniswapFeeDebt(receiver);

    emit NeutralWithdrawal(receiver, shares, 0, wethAmount);
    return wethAmount;
  }
  
  /// @notice Check if user has approved vault to spend their liquid tokens
  /// @param owner Address of the token owner
  /// @param amount Amount to check approval for
  /// @return True if vault is approved for the amount
  function hasApproval(address owner, uint256 amount) external view returns (bool) {
    return liquidToken.allowance(owner, address(this)) >= amount;
  }

  /// @notice Helper function to get the vault address for approvals
  /// @return The address that users need to approve for withdrawals
  function getVaultAddress() external view returns (address) {
    return address(this);
  }

  /// @notice Get current approval amount from owner to vault
  /// @param owner Address of the token owner
  /// @return Current approval amount
  function getApproval(address owner) external view returns (uint256) {
    return liquidToken.allowance(owner, address(this));
  }

  /// @notice Get detailed position information (v4: ticks from strategy, liquidity from PositionManager).
  /// @return tickLower The lower end of the tick range for the position
  /// @return tickUpper The higher end of the tick range for the position
  /// @return liquidity The liquidity of the position
  /// @return feeGrowthInside0LastX128 Unused for v4 (returns 0)
  /// @return feeGrowthInside1LastX128 Unused for v4 (returns 0)
  /// @return tokensOwed0 Unused for v4 (returns 0)
  /// @return tokensOwed1 Unused for v4 (returns 0)
  function getPositionDetails() external view returns (int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1) {
    if (address(strategy) == address(0)) return (0, 0, 0, 0, 0, 0, 0);
    
    uint256 positionId_ = IFloatStrategyV4(address(strategy)).getPositionId();
    if (positionId_ == 0) return (0, 0, 0, 0, 0, 0, 0);
    
    (tickLower, tickUpper) = IFloatStrategyV4Ticks(address(strategy)).tickRange();
    liquidity = positionManagerV4.getPositionLiquidity(positionId_);
    feeGrowthInside0LastX128 = 0;
    feeGrowthInside1LastX128 = 0;
    tokensOwed0 = 0;
    tokensOwed1 = 0;
  }

  /// @notice Rescue ERC20 tokens sent to the contract by mistake
  /// @dev Only owner can rescue tokens. Cannot rescue asset or liquid token as they are part of the vault.
  /// @param _token Address of the token to rescue
  /// @param _recipient Address to send the rescued tokens to
  function rescueToken(address _token, address _recipient) external onlyOwner {

    require(_token != address(0), "Invalid token address");
    require(_recipient != address(0), "Invalid recipient address");
    
    uint256 amount = IERC20(_token).balanceOf(address(this));
    require(amount > 0, "No tokens to rescue");
    
    IERC20(_token).safeTransfer(_recipient, amount);
    emit TokenRescued(_token, _recipient, amount);
  }

  function unpauseNeutralWithdrawal() external onlyOwner {
    neutralWithdrawalPaused = false;
  }

  function pauseNeutralWithdrawal() external onlyOwner {
    neutralWithdrawalPaused = true;
  }

  receive() external payable {
    revert("use depositETH");
  }
}






