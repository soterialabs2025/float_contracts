// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./FloatLiquidToken.sol";
import "./interfaces/IContractManager.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IBurn.sol";
import "./libraries/Math.sol";
import "./interfaces/IFloatStrategyV2.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/ISwapRouter.sol";
import "./interfaces/IFloatVault.sol";
import "./interfaces/IUniswapV3PoolMinimal.sol";
import "./interfaces/IUniswapV3Factory.sol";

interface IWETH is IERC20 {
  function deposit() external payable;
}

/// @title FloatVaultV2
/// @notice Float vault paired with FloatStrategyV2. No NEUTRAL mode / neutral withdrawal flows.
contract FloatVaultV2 is Ownable, ReentrancyGuard, Pausable, IFloatVault {

  using SafeERC20 for IERC20;

  IERC20 public asset;
  IERC20 public weth;
  IFloatStrategyV2 public strategy;
  FloatLiquidToken public liquidToken;
  IContractManager public immutable _manager;
  ISwapRouter public swapRouter;

  address public assetAddress;
  address public liquidTokenAddress;
  address public strategyAddr;
  address public swapRouterAddr;
  address private demeterAddr;
  address private constant WETH_ADDR = 0x4200000000000000000000000000000000000006;
  address private constant nonfungiblePositionManagerAddr = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
  bool public contractSetUp;

  event ContractSetUp(address indexed caller);
  event TokenRescued(address indexed token, address indexed recipient, uint256 amount);
  event Deposit(address indexed depositor, uint256 amount, uint256 shares);
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
    _manager = IContractManager(_managerAddr);
    contractSetUp = false;
  }

  function setUpContract() external onlyOwner  {
    assetAddress = _manager.getAddress("ASSET");
    liquidTokenAddress = _manager.getAddress("FloatLiquidToken");
    // Same manager key as V1 / FloatLiquidToken stack (`FloatStrategyV2` is not registered on current manager).
    strategyAddr = _manager.getAddress("FloatStrategy");
    swapRouterAddr = _manager.getAddress("FloatSwapRouter");
    demeterAddr = _manager.getAddress("Demeter");
    require(assetAddress != address(0), "ASSET=0");
    require(liquidTokenAddress != address(0), "liquidToken=0");
    require(strategyAddr != address(0), "strategy=0");
    strategy = IFloatStrategyV2(strategyAddr);
    asset = IERC20(assetAddress);
    weth = IERC20(WETH_ADDR);
    liquidToken = FloatLiquidToken(liquidTokenAddress);
    if (swapRouterAddr != address(0)) {
      swapRouter = ISwapRouter(swapRouterAddr);
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
    if (_msgSender() != _manager.getAddress("FloatKeeper")) revert Unauthorized();
    _;
  }

  function updateAsset() external onlyAuthorized {
    assetAddress = _manager.getAddress("ASSET");
    asset = IERC20(assetAddress);
  }

  /// @inheritdoc IFloatVault
  /// @dev Callable only by `FloatKeeper` (per manager). Demeter triggers via `FloatKeeper.snapshotVaultPoolValue()`.
  function recordPoolValueSnapshot() external override onlyFloatKeeper {
    require(contractSetUp, "not initialized");
    require(address(strategy) != address(0), "no strategy");
    _syncUniswapFees();
    uint256 pv = IFloatStrategyV2(address(strategy)).poolValue();
    uint256 fees = IFloatStrategyV2(address(strategy)).UniswapFeesCollected();
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
    uint256 g = IFloatStrategyV2(address(strategy)).UniswapFeesCollected();
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
    uint256 g = IFloatStrategyV2(address(strategy)).UniswapFeesCollected();
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

  /// @notice Wrap native ETH to WETH and mint shares (same accounting as a direct WETH `deposit`).
  function depositETH() external payable nonReentrant returns (uint256 shares) {
    require(msg.value > 0, "zero");
    require(address(weth) != address(0), "weth not set");
    uint256 balBefore = weth.balanceOf(address(this));
    IWETH(WETH_ADDR).deposit{value: msg.value}();
    uint256 received = weth.balanceOf(address(this)) - balBefore;
    require(received > 0, "no WETH received");
    shares = _depositWethAmount(_msgSender(), received);
  }

  /// @notice Deposit tokens into the vault. If tokenIn is not WETH it is swapped to WETH
  ///         via the Uniswap UniversalRouter before being forwarded to the strategy.
  /// @param tokenIn  Token the caller is depositing. Pass WETH_ADDR to deposit WETH directly.
  /// @param amount   Amount of tokenIn to deposit (in tokenIn decimals).
  /// @return shares  Liquid-token shares minted to the caller.
  function deposit(address tokenIn, uint256 amount) external nonReentrant returns (uint256 shares) {
    require(tokenIn != address(0), "tokenIn=0");
    require(amount > 0, "zero");
    require(address(weth) != address(0), "weth not set");
    address depositor = _msgSender();

    uint256 balBefore = weth.balanceOf(address(this));
    uint256 received;

    if (tokenIn == WETH_ADDR) {
      weth.safeTransferFrom(depositor, address(this), amount);
      received = weth.balanceOf(address(this)) - balBefore;
      require(received > 0, "no WETH received");
    } else {
      require(address(swapRouter) != address(0), "swapRouter not set");
      IERC20(tokenIn).safeTransferFrom(depositor, address(this), amount);
      uint256 currentAllowance = IERC20(tokenIn).allowance(address(this), address(swapRouter));
      if (currentAllowance < amount) {
        IERC20(tokenIn).approve(address(swapRouter), type(uint256).max);
      }
      uint256 wethOut = swapRouter.swapToWethViaUniversalRouter(tokenIn, amount, address(this));
      require(wethOut > 0, "swap returned 0");
      received = weth.balanceOf(address(this)) - balBefore;
      require(received > 0, "no WETH after swap");
    }

    shares = _depositWethAmount(depositor, received);
  }

  /// @dev `received` WETH must already sit on this vault. Syncs fees, earns into strategy, mints shares.
  function _depositWethAmount(address depositor, uint256 received) internal returns (uint256 shares) {
    require(contractSetUp, "not initialized");
    require(address(liquidToken) != address(0), "liquidToken not set");
    require(received > 0, "zero");

    _syncUniswapFees();
    uint256 supply = totalSupply();
    uint256 poolValueBefore = address(strategy) != address(0) ? strategy.balanceOfIdle() + strategy.poolValue() : 0;

    if (address(strategy) != address(0)) {
      strategy.beforeDeposit();
      _syncUniswapFees();
      poolValueBefore = strategy.balanceOfIdle() + strategy.poolValue();
    }

    _earn(received);

    if (supply == 0) {
        shares = received;
    } else if (poolValueBefore == 0) {
        shares = received;
    } else {
        shares = Math.mulDiv(received, supply, poolValueBefore);
    }

    require(shares > 0, "zero shares");

    liquidToken.mint(depositor, shares);
    _setUniswapFeeDebt(depositor);
    emit Deposit(depositor, received, shares);
  }

  /// @notice Withdraw shares and receive WETH
  /// @param shares Number of liquidToken shares to withdraw
  /// @return assets WETH value of withdrawn shares (strategy returns WETH directly to receiver)
  function withdraw(uint256 shares) external nonReentrant returns (uint256 assets) {
    require(shares > 0, "zero");

    _syncUniswapFees();
    address receiver = _msgSender();
    uint256 userBalance = liquidToken.balanceOf(receiver);
    require(shares <= userBalance, "Insufficient shares");

    uint256 totalSupply_ = liquidToken.totalSupply();
    require(totalSupply_ > 0, "No supply");

    require(liquidToken.allowance(receiver, address(this)) >= shares, "Vault not approved");
    liquidToken.transferFrom(receiver, address(this), shares);

    uint256 balBefore = balance();
    IFloatStrategyV2(address(strategy)).withdraw(shares, totalSupply_, receiver);
    _syncUniswapFees();
    liquidToken.burn(address(this), shares);
    _setUniswapFeeDebt(receiver);

    assets = Math.mulDiv(balBefore, shares, totalSupply_);
    return assets;
  }


  /// @notice Check if the position is currently in range
  /// @return True if position is in range, false otherwise
  function isInRange() external view returns (bool) {
    if (address(strategy) == address(0)) return false;
    return IFloatStrategyV2(address(strategy)).readInRange();
  }

  /// @notice Get the idle balance (tokens not in pool)
  /// @return The idle balance in WETH equivalent
  function getIdleBalance() external view returns (uint256) {
    if (address(strategy) == address(0)) return 0;
    return IFloatStrategyV2(address(strategy)).balanceOfIdle();
  }

  /// @notice Get the balance of tokens in the pool
  /// @return tokenAmt Amount of ASSET in pool
  /// @return wethAmt Amount of WETH in pool
  function getPoolBalance() external view returns (uint256 tokenAmt, uint256 wethAmt) {
    if (address(strategy) == address(0)) return (0, 0);
    return IFloatStrategyV2(address(strategy)).balanceOfPool();
  }

  function changeAsset(address _newAssetAddr, address _newPoolV3Addr) external onlyOwner nonReentrant {
    require(address(strategy) != address(0), "No strategy set");

    _syncUniswapFees();
    IFloatStrategyV2(address(strategy)).changeAsset(_newAssetAddr, _newPoolV3Addr);
    _syncUniswapFees();
    emit AssetChanged(_newAssetAddr);
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

  /// @notice Get detailed position information from Uniswap V3
  function getPositionDetails() external view returns (int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1) {
    if (address(strategy) == address(0)) return (0, 0, 0, 0, 0, 0, 0);

    uint256 positionId_ = IFloatStrategyV2(address(strategy)).getPositionId();
    if (positionId_ == 0) return (0, 0, 0, 0, 0, 0, 0);

    INonfungiblePositionManager npm = INonfungiblePositionManager(nonfungiblePositionManagerAddr);
    (, , , , , tickLower, tickUpper, liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128, tokensOwed0, tokensOwed1) = npm.positions(positionId_);
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

  receive() external payable {
    revert("use depositETH");
  }
}
