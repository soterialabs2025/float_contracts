// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {AutoVaultBv4} from "../contracts/auto-vault-base-v4/AutoVaultBv4.sol";
import {LiquidSharesBv4} from "../contracts/auto-vault-base-v4/LiquidSharesBv4.sol";
import {IAutoStrategyBv4} from "../contracts/auto-vault-base-v4/interfaces/IAutoStrategyBv4.sol";
import {V4Deployments8453} from "../contracts/v4/V4Deployments8453.sol";

contract MockWETH is ERC20 {
    constructor() ERC20("WETH", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract MockOperatorRegistry {
    mapping(address => bool) public isOperator;

    function setOperator(address account, bool allowed) external {
        isOperator[account] = allowed;
    }
}

contract MockStrategyBv4 {
    uint256 public nav;
    uint256 public feesCollected;
    address public keeperAddr;
    address public operatorRegistry;
    IERC20 public weth;
    IERC20 public assetToken;

    function setOperatorRegistry(address registry) external {
        operatorRegistry = registry;
    }

    constructor(address weth_, address asset_) {
        weth = IERC20(weth_);
        assetToken = IERC20(asset_);
        keeperAddr = address(this);
    }

    function setFees(uint256 fees_) external {
        feesCollected = fees_;
    }

    function addFees(uint256 delta_) external {
        feesCollected += delta_;
    }

    function poolValue() external view returns (uint256) {
        return nav;
    }

    function UniswapFeesCollected() external view returns (uint256) {
        return feesCollected;
    }

    function keeper() external view returns (address) {
        return keeperAddr;
    }

    function deposit(uint256 amount) external {
        weth.transferFrom(msg.sender, address(this), amount);
        nav += amount;
    }

    function withdraw(uint256 userShares, address receiver, IAutoStrategyBv4.WithdrawToken outToken) external {
        uint256 supply = AutoVaultBv4(payable(msg.sender)).totalSupply();
        uint256 payout = supply == 0 ? 0 : nav * userShares / supply;
        nav -= payout;
        if (outToken == IAutoStrategyBv4.WithdrawToken.WETH) {
            weth.transfer(receiver, payout);
        } else {
            assetToken.transfer(receiver, payout);
        }
    }

    receive() external payable {}
}

contract MockAsset is ERC20 {
    constructor() ERC20("ASSET", "ASSET") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AutoVaultBv4AccTest is Test {
    address internal constant WETH_ADDR = V4Deployments8453.WETH;

    AutoVaultBv4 internal vault;
    LiquidSharesBv4 internal ls;
    MockStrategyBv4 internal strategy;
    MockOperatorRegistry internal registry;
    MockAsset internal asset;

    address internal factory = address(0xFA70);
    address internal owner = address(0x1001);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal staking = address(0x571A);

    function setUp() public {
        MockWETH wethImpl = new MockWETH();
        vm.etch(WETH_ADDR, address(wethImpl).code);

        asset = new MockAsset();
        asset.mint(address(this), 1_000_000 ether);

        vault = new AutoVaultBv4(factory);
        ls = new LiquidSharesBv4(factory);
        strategy = new MockStrategyBv4(WETH_ADDR, address(asset));
        registry = new MockOperatorRegistry();
        strategy.setOperatorRegistry(address(registry));

        vm.startPrank(factory);
        ls.bootstrap(address(vault));
        vault.bootstrap(owner, address(strategy), address(ls), staking, address(asset));
        vm.stopPrank();

        vm.deal(owner, 1000 ether);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _deposit(address user, uint256 ethAmount) internal returns (uint256 shares) {
        vm.prank(user);
        shares = vault.depositETH{value: ethAmount}();
    }

    function test_bootstrapSyncsFeesWithoutBackfill() public view {
        assertEq(vault.accUniswapFeesPerShare(), 0);
        assertEq(vault.uniswapFeesCollectedSynced(), 0);
    }

    function test_firstDepositAccUnchangedWhenFeesFlat() public {
        vm.recordLogs();
        _deposit(owner, 100 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(vault.accUniswapFeesPerShare(), 0);

        bytes32 depositTopic = keccak256("Deposit(address,uint256,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == depositTopic) {
                (,, uint256 acc) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(acc, 0);
                found = true;
            }
        }
        assertTrue(found);
    }

    function test_syncAccBeforeMintAttributesFeesToExistingHolders() public {
        _deposit(owner, 100 ether);

        strategy.addFees(100 ether);
        vm.prank(alice);
        vault.depositETH{value: 1 ether}();

        uint256 expectedAcc = 100 ether * 1e18 / 100 ether;
        assertEq(vault.accUniswapFeesPerShare(), expectedAcc);
        assertEq(vault.uniswapFeesCollectedSynced(), 100 ether);
    }

    function test_bobStartsAtCurrentAccAfterPriorFees() public {
        _deposit(owner, 100 ether);
        strategy.addFees(100 ether);

        vm.prank(alice);
        vault.depositETH{value: 1 ether}();
        uint256 accBeforeBob = vault.accUniswapFeesPerShare();

        vm.recordLogs();
        vm.prank(bob);
        vault.depositETH{value: 10 ether}();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 depositTopic = keccak256("Deposit(address,uint256,uint256,uint256)");
        uint256 bobAcc;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == depositTopic && logs[i].topics[1] == bytes32(uint256(uint160(bob)))) {
                (,, bobAcc) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
        assertEq(bobAcc, accBeforeBob);
        assertEq(bobAcc, vault.accUniswapFeesPerShare());
    }

    function test_dappFormulaMatchesAccIntervals() public {
        _deposit(owner, 100 ether);
        strategy.addFees(100 ether);
        vm.prank(alice);
        vault.depositETH{value: 1 ether}();

        uint256 accAtAliceDeposit = vault.accUniswapFeesPerShare();
        uint256 aliceShares = vault.balanceOf(alice);

        strategy.addFees(50 ether);
        vm.prank(bob);
        vault.depositETH{value: 50 ether}();

        uint256 accNow = vault.accUniswapFeesPerShare();
        uint256 aliceFromFirstInterval = 100 ether * (accAtAliceDeposit - 0) / 1e18;
        uint256 aliceFromSecond = aliceShares * (accNow - accAtAliceDeposit) / 1e18;
        assertEq(aliceFromFirstInterval, 100 ether);
        assertGt(aliceFromSecond, 0);
    }

    function test_secondDepositSyncsBeforeMint() public {
        _deposit(owner, 100 ether);
        strategy.addFees(10 ether);

        vm.prank(alice);
        vault.depositETH{value: 10 ether}();
        uint256 accAfterFirst = vault.accUniswapFeesPerShare();

        strategy.addFees(10 ether);
        vm.prank(alice);
        vault.depositETH{value: 10 ether}();

        assertGt(vault.accUniswapFeesPerShare(), accAfterFirst);
    }

    function test_zeroSupplyDoesNotDivide() public {
        strategy.setFees(50 ether);
        _deposit(owner, 1 ether);
        assertEq(vault.accUniswapFeesPerShare(), 0);
        assertEq(vault.uniswapFeesCollectedSynced(), 50 ether);
    }

    function test_withdrawEmitsAccAndPreservesShareMath() public {
        uint256 ownerShares = _deposit(owner, 100 ether);
        strategy.addFees(20 ether);

        vm.recordLogs();
        vm.prank(owner);
        uint256 received = vault.withdraw(ownerShares / 2, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(received, 0);
        assertEq(vault.balanceOf(owner), ownerShares / 2);

        bytes32 withdrawTopic = keccak256("Withdraw(address,uint256,bool,uint256,uint256)");
        uint256 emittedAcc;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == withdrawTopic) {
                (,, emittedAcc) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
        assertEq(emittedAcc, vault.accUniswapFeesPerShare());
    }

    // --- pause ---

    function test_pauseBlocksDeposits() public {
        _deposit(owner, 100 ether);

        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.depositETH{value: 1 ether}();
    }

    /// @dev The pause deliberately does not cover exits, so it cannot be used to trap depositor funds.
    function test_withdrawStaysOpenWhilePaused() public {
        uint256 shares = _deposit(owner, 100 ether);

        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        uint256 received = vault.withdraw(shares, false);
        assertGt(received, 0);
        assertEq(vault.balanceOf(owner), 0);
    }

    function test_depositResumesAfterUnpause() public {
        _deposit(owner, 100 ether);

        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vault.unpause();

        assertFalse(vault.paused());
        assertGt(_deposit(alice, 1 ether), 0);
    }

    /// @dev Operators trip the pause for fast incident response but cannot clear it; recovery stays with the owner.
    function test_operatorCanPauseButNotUnpause() public {
        registry.setOperator(alice, true);

        vm.prank(alice);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.unpause();
        assertTrue(vault.paused());
    }

    function test_nonOperatorCannotPause() public {
        vm.prank(bob);
        vm.expectRevert(AutoVaultBv4.Unauthorized.selector);
        vault.pause();
    }

    function test_revokedOperatorCannotPause() public {
        registry.setOperator(alice, true);
        registry.setOperator(alice, false);

        vm.prank(alice);
        vm.expectRevert(AutoVaultBv4.Unauthorized.selector);
        vault.pause();
    }
}
