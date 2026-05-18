// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LiquidToken.sol";  
import "./interfaces/IContractManager.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol"; 
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IBurn.sol";
import "./libraries/Math.sol";
import "./interfaces/ILiquidStrategy.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/ISwapRouter.sol";
import "./interfaces/IUniswapV3PoolMinimal.sol";
import "./interfaces/IUniswapV3Factory.sol";

contract LiquidVault is Ownable, ReentrancyGuard, Pausable {
   
  using SafeERC20 for IERC20;

  IERC20 public asset;
  IERC20 public weth;
  ILiquidStrategy public strategy;
  LiquidToken public liquidToken;
  IContractManager public immutable _manager;
  ISwapRouter public swapRouter;

  address public assetAddress;
  address public liquidTokenAddress;
  address public strategyAddr;
  address public swapRouterAddr;
  address private constant WETH_ADDR = 0x4200000000000000000000000000000000000006;
   address private constant nonfungiblePositionManagerAddr = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
  bool public contractSetUp;
  bool public retired;
  bool public retireWithdrawalPaused = true;
  uint256 public retiredPoolValue;
  uint256 public retiredTokenBalance;
  uint256 public retiredWethBalance;
  uint256 public retiredTotalSupply;
  
  event ContractSetUp(address indexed caller);
  event TokenRescued(address indexed token, address indexed recipient, uint256 amount);
  event Deposit(address indexed depositor, uint256 amount, uint256 shares);
  event StrategyRetired(uint256 vaultValue);
  event RetireWithdrawal(address indexed receiver, uint256 shares, uint256 tokenAmount, uint256 wethAmount);
  event AssetChanged(address indexed newAsset); 
  constructor(address _managerAddr) Ownable(_msgSender()) {
   require(_managerAddr != address(0), "Invalid manager address"); 
    _manager = IContractManager(_managerAddr);
    contractSetUp = false;
  } 

  function setUpContract() external onlyOwner  {
    assetAddress = _manager.getAddress("LiquidASSET");
    liquidTokenAddress = _manager.getAddress("LiquidToken");
    strategyAddr = _manager.getAddress("LiquidStrategy");
    swapRouterAddr = _manager.getAddress("LiquidSwapRouter");
    strategy = ILiquidStrategy(strategyAddr);
    asset = IERC20(assetAddress);
    weth = IERC20(WETH_ADDR);
    liquidToken = LiquidToken(liquidTokenAddress);
    if (swapRouterAddr != address(0)) {
      swapRouter = ISwapRouter(swapRouterAddr);
    }
    contractSetUp = true;
    emit ContractSetUp(_msgSender());
  }
  
  error Unauthorized();

  modifier onlyAuthorized() {
    address s = _msgSender();
    if (s != address(_manager) && s != owner()) revert Unauthorized();
    _;
  }

  function updateAsset() external onlyAuthorized {
    assetAddress = _manager.getAddress("LiquidASSET");
    asset = IERC20(assetAddress);
  } 


   function balance() public view returns (uint256) {
    if (address(strategy) == address(0)) return 0;
    return strategy.vaultValue();
  }

  function totalSupply() public view returns (uint256) {
    return liquidToken.totalSupply();
  }


  /// @notice Get available WETH balance in vault (for deposits)
  /// @return Available WETH balance
  function available() public view returns (uint256) {
    return address(weth) != address(0) ? weth.balanceOf(address(this)) : 0;
  }
  
  /// @notice Get available LiquidASSET balance in vault
  /// @return Available ASSET balance
  function availableAsset() public view returns (uint256) {
    return asset.balanceOf(address(this));
  }

  function getPricePerFullShare() public view returns (uint256) {
    return liquidToken.totalSupply() == 0 ? 1e18 : balance() * 1e18 / liquidToken.totalSupply();
  }

  function _earn(uint256 wethAmount) internal {
    if (wethAmount > 0 && address(strategy) != address(0)) {
      weth.safeTransfer(address(strategy), wethAmount);
      strategy.deposit(wethAmount);
    }
  }
  

  /// @notice Deposit tokens into the vault. If tokenIn is not WETH it is swapped to WETH
  ///         via the Uniswap UniversalRouter before being forwarded to the strategy.
  /// @param tokenIn  Token the caller is depositing. Pass WETH_ADDR to deposit WETH directly.
  /// @param amount   Amount of tokenIn to deposit (in tokenIn decimals).
  /// @return shares  Liquid-token shares minted to the caller.
  function deposit(address tokenIn, uint256 amount) external nonReentrant returns (uint256 shares) {
    require(!retired, "Strategy retired");
    require(contractSetUp, "not initialized");
    require(address(liquidToken) != address(0), "liquidToken not set");
    require(address(weth) != address(0), "weth not set");
    require(tokenIn != address(0), "tokenIn=0");
    require(amount > 0, "zero");
    address depositor = _msgSender();
    uint256 supply = totalSupply();
    uint256 navBefore = 0;
    if (address(strategy) != address(0)) {
      strategy.beforeDeposit();
      navBefore = strategy.vaultValue();
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
      uint256 wethOut = swapRouter.swapToWethViaUniversalRouter(tokenIn, amount, address(this));
      require(wethOut > 0, "swap returned 0");
      received = weth.balanceOf(address(this)) - balBefore;
      require(received > 0, "no WETH after swap");
    }

    _earn(received);

    uint256 navAfter = address(strategy) != address(0) ? strategy.vaultValue() : 0;
    uint256 valueAdded = navAfter > navBefore ? navAfter - navBefore : 0;
    require(valueAdded > 0, "zero value added");

    // Mint from actual WETH-denominated NAV delta (covers WETH→ASSET slippage vs using raw `received`).
    if (supply == 0 || navBefore == 0) {
      shares = valueAdded;
    } else {
      shares = Math.mulDiv(valueAdded, supply, navBefore);
    }

    require(shares > 0, "zero shares");

    liquidToken.mint(depositor, shares);
    emit Deposit(depositor, valueAdded, shares);
  }

  /// @notice Re-deposit remaining WETH into the strategy to un-retire the vault.
  /// @dev Only valid after retireStrategy(). Transfers the remaining retiredWethBalance
  ///      (i.e. WETH not yet claimed via retireWithdrawal) back into the strategy.
  ///      Existing share-holders who did NOT call retireWithdrawal retain proportional
  ///      ownership automatically — no new shares are minted.
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

    // Transfer WETH to strategy and deposit (matches the normal vault→strategy deposit flow)
    weth.safeTransfer(address(strategy), wethToDeposit);
    strategy.deposit(wethToDeposit);

    uint256 poolValueAfter = strategy.vaultValue();
    require(poolValueAfter > poolValueBefore, "No pool value increase after deposit");

    // Reset retired state before emitting
    retired = false;
    retiredTokenBalance = 0;
    retiredWethBalance = 0;
    retiredPoolValue = 0;
    retiredTotalSupply = 0;

    emit Deposit(address(this), wethToDeposit, 0);
  }

  /// @notice Withdraw shares and receive WETH
  /// @param shares Number of liquidToken shares to withdraw
  /// @return assets WETH value of withdrawn shares (strategy returns WETH directly to receiver)
  function withdraw(uint256 shares) external nonReentrant returns (uint256 assets) {
    require(!retired, "Strategy retired - use retireWithdrawal()");
    require(shares > 0, "zero");
    
    address receiver = _msgSender();
    uint256 userBalance = liquidToken.balanceOf(receiver);
    require(shares <= userBalance, "Insufficient shares");
    
    uint256 totalSupply_ = liquidToken.totalSupply();
    require(totalSupply_ > 0, "No supply");
     
    require(liquidToken.allowance(receiver, address(this)) >= shares, "Vault not approved");
    liquidToken.transferFrom(receiver, address(this), shares);
    
    uint256 balBefore = balance(); // WETH-denominated value
    ILiquidStrategy(address(strategy)).withdraw(shares, totalSupply_, receiver); 
    liquidToken.burn(address(this), shares);
    
    assets = Math.mulDiv(balBefore, shares, totalSupply_); // Returns WETH value
    return assets;
  }
 


  /// @notice Total strategy value in WETH terms (`vaultValue` on the strategy).
  /// @return WETH-equivalent NAV held by the strategy
  function getIdleBalance() external view returns (uint256) {
    if (address(strategy) == address(0)) return 0;
    return ILiquidStrategy(address(strategy)).vaultValue();
  }

  /// @notice ASSET and WETH sitting on the strategy (LiquidStrategy does not hold Uniswap V3 LP).
  /// @return tokenAmt Idle ASSET on the strategy
  /// @return wethAmt Idle WETH on the strategy
  function getPoolBalance() external view returns (uint256 tokenAmt, uint256 wethAmt) {
    if (address(strategy) == address(0)) return (0, 0);
    return (asset.balanceOf(address(strategy)), weth.balanceOf(address(strategy)));
  }
 
  /// @notice Retire the strategy in emergency situations.
  /// @dev Calls strategy.withdraw for 100% of shares, draining all liquidity, collecting fees,
  ///      swapping ASSET→WETH inside the strategy, and returning all WETH to this vault.
  ///      retiredWethBalance is then used for proportional user withdrawals via retireWithdrawal().
  function retireStrategy() external onlyOwner nonReentrant {
    require(!retired, "Strategy already retired");
    require(address(strategy) != address(0), "No strategy set");

    uint256 totalSupply_ = liquidToken.totalSupply();
    require(totalSupply_ > 0, "No shares outstanding");

    retiredPoolValue = ILiquidStrategy(address(strategy)).vaultValue();
    require(retiredPoolValue > 0, "No pool value to retire");

    // Store supply snapshot before draining
    retiredTotalSupply = totalSupply_;
    retiredTokenBalance = 0;

    // Drain strategy: decreases all pool liquidity, swaps ASSET→WETH, transfers WETH here.
    // Passing userShares == totalSupply_ → 100% proportion withdrawn.
    uint256 wethBefore = weth.balanceOf(address(this));
    strategy.withdraw(totalSupply_, totalSupply_, address(this));
    retiredWethBalance = weth.balanceOf(address(this)) - wethBefore;

    retired = true;
    emit StrategyRetired(retiredPoolValue);
  }

  function changeAsset(address _newAssetAddr, address _newPoolV3Addr) external onlyOwner nonReentrant {
    require(address(strategy) != address(0), "No strategy set");
    
    // Get pool value before retirement
    ILiquidStrategy(address(strategy)).changeAsset(_newAssetAddr, _newPoolV3Addr);
    emit AssetChanged(_newAssetAddr);
  }


  /// @notice Withdraw user's proportional WETH share after strategy retirement.
  /// @dev retiredWethBalance is decremented on each call to keep accounting exact.
  ///      No withdrawal fees applied — this is an emergency exit path.
  /// @param shares Number of liquidToken shares to redeem
  /// @return wethAmount Amount of WETH returned to caller
  function retireWithdrawal(uint256 shares) external nonReentrant returns (uint256 wethAmount) {
    require(!retireWithdrawalPaused, "Retire withdrawal paused");
    require(retired, "Strategy not retired");
    require(shares > 0, "zero shares");
    require(retiredTotalSupply > 0, "Invalid retired total supply");

    address receiver = _msgSender();
    require(shares <= liquidToken.balanceOf(receiver), "Insufficient shares");
    require(liquidToken.allowance(receiver, address(this)) >= shares, "Vault not approved");

    liquidToken.transferFrom(receiver, address(this), shares);

    // Proportional share of WETH held at time of retirement.
    // retiredTotalSupply is fixed at retirement so each user's entitlement stays
    // consistent regardless of how many others have already withdrawn.
    wethAmount = Math.mulDiv(retiredWethBalance, shares, retiredTotalSupply);

    // Cap against actual vault WETH balance (guards against dust rounding)
    uint256 vaultWethBal = weth.balanceOf(address(this));
    if (wethAmount > vaultWethBal) wethAmount = vaultWethBal;

    // Decrement the tracking balance so subsequent callers get accurate entitlements
    retiredWethBalance -= wethAmount;

    if (wethAmount > 0) {
      weth.safeTransfer(receiver, wethAmount);
    }

    liquidToken.burn(address(this), shares);

    emit RetireWithdrawal(receiver, shares, 0, wethAmount);
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

  function unpauseRetireWithdrawal() external onlyOwner {
    retireWithdrawalPaused = false;
  }

  function pauseRetireWithdrawal() external onlyOwner {
    retireWithdrawalPaused = true;
  }


}






