// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IFloatV4ContractManager.sol";
import "./interfaces/IFloatStrategyV4.sol";
import "./interfaces/IFloatVaultV4.sol";
import "../../interfaces/IPositionManagerV4.sol";
import "./interfaces/IFloatLiquidTokenVault.sol";
import "./interfaces/IFloatStrategyV4Ticks.sol";
import "./interfaces/ISwapRouterV4.sol";
import "./V4Deployments8453.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FloatVaultV4
/// @notice Same economics as `FloatVault`, but deposits swap via `ISwapRouterV4` (UR `V4_SWAP`) and position details read v4 PM + strategy ticks.
/// @dev Register `FloatSwapRouterV4` / `FloatStrategyV4` (or your chosen names) on the contract manager. `positionManagerV4` uses Base (8453) deployment constant from `V4Deployments8453`.
contract FloatVaultV4 is Ownable, ReentrancyGuard, Pausable, IFloatVaultV4 {
   
  using SafeERC20 for IERC20;

  IERC20 public asset;
  IERC20 public weth;
  IFloatStrategyV4 public strategy;
  IFloatLiquidTokenVault public liquidToken;
  IFloatV4ContractManager public immutable _manager;
  ISwapRouterV4 public swapRouter;

  /// @notice Uniswap v4 PositionManager (for `getPositionDetails` liquidity); Base mainnet address from deployments doc.
  IPositionManagerV4 public immutable positionManagerV4;

  address public assetAddress;
  address public liquidTokenAddress;
  address public strategyAddr;
  address public swapRouterAddr;
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
  event PoolValueSnapshotRecorded(uint256 valueWeth, uint64 timestamp);

  /// @dev Scaled accumulator for `UniswapFeesCollected` growth per liquid share (WETH-notional attribution, not a claim).
  uint256 public constant FEES_PER_SHARE_PRECISION = 1e18;
  uint256 public accUniswapFeesPerShare;
  /// @notice Last `strategy.UniswapFeesCollected()` value applied into `accUniswapFeesPerShare`.
  uint256 public uniswapFeesCollectedSynced;
  mapping(address => uint256) public uniswapFeeDebt;

  /// @notice WETH-denominated Uniswap position value from the strategy at snapshot time (see `IFloatStrategyV4.poolValue()`).
  struct PoolValueSnapshot {
    uint256 valueWeth;
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
    swapRouterAddr = _manager.getAddress("FloatSwapRouterV4");
    demeterAddr = _manager.getAddress("Demeter");
    strategy = IFloatStrategyV4(strategyAddr);
    asset = IERC20(assetAddress);
    weth = IERC20(WETH_ADDR);
    liquidToken = IFloatLiquidTokenVault(liquidTokenAddress);
    if (swapRouterAddr != address(0)) {
      swapRouter = ISwapRouterV4(swapRouterAddr);
    }
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

  function updateAsset() external onlyAuthorized {
    assetAddress = _manager.getAddress("ASSET");
    asset = IERC20(assetAddress);
  }

  /// @inheritdoc IFloatVaultV4
  /// @dev Callable only by `FloatKeeperV4` (per manager). Demeter triggers via `FloatKeeperV4.snapshotVaultPoolValue()`.
  function recordPoolValueSnapshot() external override onlyFloatKeeper {
    require(contractSetUp, "not initialized");
    require(address(strategy) != address(0), "no strategy");
    _syncUniswapFees();
    uint256 pv = IFloatStrategyV4(address(strategy)).poolValue();
    poolValueSnapshots.push(
      PoolValueSnapshot({valueWeth: pv, timestamp: uint64(block.timestamp)})
    );
    emit PoolValueSnapshotRecorded(pv, uint64(block.timestamp));
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
  

  /// @notice Deposit tokens into the vault. If tokenIn is not WETH it is swapped to WETH
  ///         via `FloatSwapRouterV4` / Universal Router `V4_SWAP` before being forwarded to the strategy.
  /// @param tokenIn  Token the caller is depositing. Pass WETH_ADDR to deposit WETH directly.
  /// @param amount   Amount of tokenIn to deposit (in tokenIn decimals).
  /// @param minOutIfNoQuoter When `tokenIn` is not WETH, minimum WETH out if the router has no working quoter (else slippage comes from router defaults + quote).
  /// @return shares  Liquid-token shares minted to the caller.
  function deposit(address tokenIn, uint256 amount, uint128 minOutIfNoQuoter) external nonReentrant returns (uint256 shares) {
    require(!neutral, "Vault neutral");
    require(contractSetUp, "not initialized");
    require(address(liquidToken) != address(0), "liquidToken not set");
    require(address(weth) != address(0), "weth not set");
    require(tokenIn != address(0), "tokenIn=0");
    require(amount > 0, "zero");
    address depositor = _msgSender();
    _syncUniswapFees();
    uint256 supply = totalSupply();
    // Measure total vault value BEFORE beforeDeposit (idle + Uniswap position, WETH-denominated)
    uint256 poolValueBefore = address(strategy) != address(0) ? strategy.balanceOfIdle() + strategy.poolValue() : 0;

    if (address(strategy) != address(0)) {
      strategy.beforeDeposit();
      _syncUniswapFees();
      // Re-measure after beforeDeposit in case it harvested/changed value
      poolValueBefore = strategy.balanceOfIdle() + strategy.poolValue();
    }

    uint256 balBefore = weth.balanceOf(address(this));
    uint256 received;

    if (tokenIn == WETH_ADDR) { 
      // ── Direct WETH deposit ──────────────────────────────────────────────
      weth.safeTransferFrom(depositor, address(this), amount);
      received = weth.balanceOf(address(this)) - balBefore;
      require(received > 0, "no WETH received");
    } else {
      // ── Non-WETH: pull token then swap to WETH via UniversalRouter ───────
      require(address(swapRouter) != address(0), "swapRouter not set");
      // Pull tokenIn from depositor into this vault
      IERC20(tokenIn).safeTransferFrom(depositor, address(this), amount);
      // Approve swapRouter to pull tokenIn
      uint256 currentAllowance = IERC20(tokenIn).allowance(address(this), address(swapRouter));
      if (currentAllowance < amount) {
        IERC20(tokenIn).approve(address(swapRouter), type(uint256).max);
      }
      // Swap tokenIn → WETH; WETH lands directly in this vault (recipient = address(this))
      uint256 wethOut =
        swapRouter.swapToWethViaUniversalRouterV4(tokenIn, amount, address(this), minOutIfNoQuoter);
      require(wethOut > 0, "swap returned 0");
      received = weth.balanceOf(address(this)) - balBefore;
      require(received > 0, "no WETH after swap");
    }

    // Transfer WETH to strategy
    _earn(received);
    
    // Share calculation uses only strategy accounting views (idle + pool WETH value). It does not use
    // FloatStrategy._checkTokenShare() — that function is for LP deviation / keeper risk, not mint math.
    // Both received and poolValueBefore are WETH-denominated.
    if (supply == 0) {
        // First deposit: mint 1:1 with deposited WETH amount
        shares = received;
    } else if (poolValueBefore == 0) {
        // Edge case: supply exists but pool value is 0 (shouldn't happen normally)
        // Use received amount to maintain consistency
        shares = received;
    } else {
        // Subsequent deposits: calculate shares based on WETH-denominated pool value
        // Formula: shares = (depositedWETH * totalSupply) / poolValueBefore
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
 
  /// @notice Emergency: drain strategy to WETH in this vault and enter NEUTRAL on the strategy.
  /// @dev Full proportional withdraw; `neutralWethBalance` backs `neutralWithdrawal` pro-rata redemptions.
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
    neutralWethBalance = weth.balanceOf(address(this)) - wethBefore;
    _syncUniswapFees();

    neutral = true;
    emit StrategyNeutral(neutralPoolValue);
  }

  /// @param poolFeePips Uniswap v4 `fee` for the ASSET/WETH pool (e.g. 3000 = 0.30%, 10_000 = 1%).
  /// @param tickSpacing Must match the initialized pool for that fee (and `hooks`).
  /// @param hooks Pool hooks address, or `address(0)`.
  function changeAsset(address _newAssetAddr, uint24 poolFeePips, int24 tickSpacing, address hooks)
    external
    onlyOwner
    nonReentrant
  {
    require(address(strategy) != address(0), "No strategy set");

    _syncUniswapFees();
    strategy.changeAsset(_newAssetAddr, poolFeePips, tickSpacing, hooks);
    _syncUniswapFees();
    emit AssetChanged(_newAssetAddr);
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


}






