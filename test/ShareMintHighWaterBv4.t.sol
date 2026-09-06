// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AutoVaultBv4} from "../contracts/auto-vault-base-v4/AutoVaultBv4.sol";
import {LiquidSharesBv4} from "../contracts/auto-vault-base-v4/LiquidSharesBv4.sol";
import {IAutoStrategyBv4} from "../contracts/auto-vault-base-v4/interfaces/IAutoStrategyBv4.sol";
import {V4Deployments8453} from "../contracts/v4/V4Deployments8453.sol";

contract HwMockWETH is ERC20 {
    constructor() ERC20("WETH", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract HwMockAsset is ERC20 {
    constructor() ERC20("ASSET", "ASSET") {}
}

/// @dev Spot NAV and reference NAV are set independently so a manipulated spot can be expressed directly. In the
///      real strategy `poolValue` resolves to `_spotPrice1e18` with nothing between it and slot0, while
///      `poolValueRef` prices the same balances at the truncated reference tick.
contract HwMockStrategy {
    uint256 public nav;
    uint256 public navRef;
    uint256 public feesCollected;
    address public operatorRegistry;
    IERC20 public weth;
    IERC20 public assetToken;

    constructor(address weth_, address asset_) {
        weth = IERC20(weth_);
        assetToken = IERC20(asset_);
    }

    /// @dev Moves spot and the reference together, i.e. a price move the reference has fully tracked.
    function setNav(uint256 nav_) external {
        nav = nav_;
        navRef = nav_;
    }

    /// @dev Moves spot only, i.e. a move faster than the clamp allows the reference to follow.
    function setSpotOnly(uint256 nav_) external {
        nav = nav_;
    }

    function setNavRef(uint256 navRef_) external {
        navRef = navRef_;
    }

    function poolValue() external view returns (uint256) {
        return nav;
    }

    function poolValueRef() external view returns (uint256) {
        return navRef;
    }

    function UniswapFeesCollected() external view returns (uint256) {
        return feesCollected;
    }

    function keeper() external view returns (address) {
        return address(this);
    }

    function deposit(uint256 amount) external {
        weth.transferFrom(msg.sender, address(this), amount);
        nav += amount;
        navRef += amount;
    }

    function withdraw(uint256 userShares, address receiver, IAutoStrategyBv4.WithdrawToken outToken) external {
        uint256 supply = AutoVaultBv4(payable(msg.sender)).totalSupply();
        uint256 payout = supply == 0 ? 0 : nav * userShares / supply;
        nav -= payout;
        navRef = navRef > payout ? navRef - payout : 0;
        if (outToken == IAutoStrategyBv4.WithdrawToken.WETH) {
            weth.transfer(receiver, payout);
        } else {
            assetToken.transfer(receiver, payout);
        }
    }

    receive() external payable {}
}

/// @dev Entry pricing for AutoVaultBv4. These replaced a suite that pinned the old `lastSharePriceX18` high-water
///      mark, which only ratcheted up and therefore bound on every deposit made below the vault's all-time high —
///      a 10 WETH deposit after a round trip in price used to be worth about 5.2 WETH, and a one-block spot spike
///      could set that toll permanently. The truncated reference replaces it, so the cases below assert that
///      ordinary drawdowns and transient spikes no longer cost a depositor anything.
contract ShareMintHighWaterBv4Test is Test {
    address internal constant WETH_ADDR = V4Deployments8453.WETH;

    AutoVaultBv4 internal vault;
    LiquidSharesBv4 internal ls;
    HwMockStrategy internal strategy;

    address internal factory = address(0xFA70);
    address internal owner = address(0x1001);
    address internal bob = address(0xB0B);
    address internal attacker = address(0xBADD);
    address internal staking = address(0x571A);

    function setUp() public {
        HwMockWETH wethImpl = new HwMockWETH();
        vm.etch(WETH_ADDR, address(wethImpl).code);

        HwMockAsset asset = new HwMockAsset();
        vault = new AutoVaultBv4(factory);
        ls = new LiquidSharesBv4(factory);
        strategy = new HwMockStrategy(WETH_ADDR, address(asset));

        vm.startPrank(factory);
        ls.bootstrap(address(vault));
        vault.bootstrap(owner, address(strategy), address(ls), staking, address(asset));
        vm.stopPrank();

        // NAV is set independently of what the mock holds, so keep it liquid enough that a payout never
        // runs it dry. These tests are about the entry price, not about solvency.
        deal(WETH_ADDR, address(strategy), 10_000 ether);

        vm.deal(owner, 10_000 ether);
        vm.deal(bob, 10_000 ether);
        vm.deal(attacker, 10_000 ether);
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        vm.prank(user);
        shares = vault.depositETH{value: amount}();
    }

    /// @dev WETH value of `shares` at the current mark.
    function _valueOf(uint256 shares) internal view returns (uint256) {
        return (shares * vault.balance()) / vault.totalSupply();
    }

    /// @dev Shares the depositor should receive at the honest price: `credited / currentPrice`.
    function _fairShares(uint256 amount) internal view returns (uint256) {
        return (amount * vault.totalSupply()) / vault.balance();
    }

    // --- the case the high-water mark used to punish ---

    /// @dev A round trip up and back. The reference tracked both legs, so the entry prices off the real,
    ///      post-drawdown NAV. Under the high-water mark this deposit was worth about half what was paid.
    function test_DepositAfterDrawdownPricesAtSpot() public {
        _deposit(owner, 100 ether);
        strategy.setNav(200 ether);
        _deposit(owner, 1 ether);
        strategy.setNav(100 ether);

        uint256 fair = _fairShares(10 ether);
        uint256 got = _deposit(bob, 10 ether);

        assertEq(got, fair, "credited at the live price, not an all-time high");
        assertApproxEqAbs(_valueOf(got), 10 ether, 0.001 ether, "10 WETH in, 10 WETH of shares out");
    }

    /// @dev Nothing accumulates across deposits any more, so a vault far below its peak is still enterable on
    ///      fair terms however long it has been there.
    function test_NoPenaltyPersistsAcrossTime() public {
        _deposit(owner, 100 ether);
        strategy.setNav(200 ether);
        _deposit(owner, 1 ether);
        strategy.setNav(100 ether);

        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 2_600_000);

        uint256 fair = _fairShares(10 ether);
        assertEq(_deposit(bob, 10 ether), fair, "a year later the entry price is still the live one");
    }

    // --- the griefing vector the high-water mark enabled ---

    /// @dev The attack that used to work: pump spot, deposit dust to ratchet the mark, unwind, and every later
    ///      depositor pays the inflated price forever. The clamp holds the reference near the honest price, so
    ///      the spike moves nothing and leaves nothing behind.
    function test_TransientSpotSpikeLeavesNoResidue() public {
        _deposit(owner, 100 ether);

        // Spot triples for one block; the reference cannot follow that fast, so it stays put.
        strategy.setSpotOnly(300 ether);
        _deposit(attacker, 1 ether);
        strategy.setSpotOnly(101 ether);

        uint256 fair = _fairShares(10 ether);
        uint256 got = _deposit(bob, 10 ether);

        assertEq(got, fair, "the spike left no mark to price against");
        assertApproxEqAbs(_valueOf(got), 10 ether, 0.001 ether);
    }

    /// @dev And the spike does not pay during it either: `min` takes the higher NAV, so an inflated spot only
    ///      earns the attacker fewer shares for their own dust deposit.
    function test_InflatedSpotOnlyShortsTheInflater() public {
        _deposit(owner, 100 ether);

        strategy.setSpotOnly(300 ether);
        uint256 attackerShares = _deposit(attacker, 3 ether);

        // Priced off the inflated spot: 3 WETH against a 300 NAV and 100 shares, not the honest 100 NAV.
        assertEq(attackerShares, 1 ether, "attacker paid the price they manufactured");
    }

    // --- direction of the residual cost ---

    /// @dev A reference lagging below spot is ignored, because `min` selects the higher NAV. So a rising market
    ///      never under-credits, which is what bounds the cost of clamping the reference slowly.
    function test_ReferenceLaggingBelowSpotIsIgnored() public {
        _deposit(owner, 100 ether);

        strategy.setSpotOnly(150 ether); // spot up, reference still at 100
        uint256 fair = _fairShares(10 ether);

        assertEq(_deposit(bob, 10 ether), fair, "rising market credits at spot");
    }

    /// @dev The mirror case, and the whole residual cost of the design: in a fast drawdown the reference is still
    ///      high, `min` picks it, and the depositor is under-credited until the reference tracks down. Bounded by
    ///      the drift rate to roughly half an hour, against the high-water mark's forever.
    function test_ReferenceLaggingAboveSpotUnderCredits() public {
        _deposit(owner, 100 ether);

        strategy.setSpotOnly(50 ether); // spot halves, reference still at 100
        uint256 fair = _fairShares(10 ether);
        uint256 got = _deposit(bob, 10 ether);

        assertLt(got, fair, "conservative direction while the reference catches up");
        assertEq(got, 10 ether, "credited at the reference, i.e. the pre-crash price");

        // Once the reference tracks down, the next depositor is priced fairly again.
        strategy.setNavRef(60 ether);
        uint256 fairLater = _fairShares(10 ether);
        assertEq(_deposit(bob, 10 ether), fairLater);
    }

    // --- degradation, not halting ---

    /// @dev A reference that never gets written must not block deposits. Zero means unseeded, and the vault
    ///      falls through to spot rather than reverting.
    function test_UnseededReferenceDoesNotBlockDeposits() public {
        _deposit(owner, 100 ether);
        strategy.setNavRef(0);

        uint256 fair = _fairShares(10 ether);
        assertEq(_deposit(bob, 10 ether), fair, "deposits stay open with no reference at all");
    }
}
