// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IShareStakingTransferHook {
    function onStakedSharesTransfer(address from, address to, uint256 amount) external;
}

/// @title StakedShares
/// @notice Cloneable receipt ERC-20 for staked LiquidSharesRhV3. Transfers notify ShareStakingRhV3 so rewards follow the holder.
contract StakedShares is Ownable {
    string private _name;
    string private _symbol;
    uint8 private constant _decimals = 18;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    address public staking;
    address public factory;
    bool public initialized;

    error Unauthorized();
    error ZeroAddress();
    error AlreadyInitialized();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() Ownable(msg.sender) {}

    function initialize(address staking_, string memory name_, string memory symbol_) public {
        if (initialized) revert AlreadyInitialized();
        if (staking_ == address(0)) revert ZeroAddress();
        factory = msg.sender;
        staking = staking_;
        _name = name_;
        _symbol = symbol_;
        initialized = true;
        _transferOwnership(staking_);
    }

    function bootstrap(address staking_) external {
        initialize(staking_, "Staked Shares", "sLS");
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external pure returns (uint8) {
        return _decimals;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != staking) revert Unauthorized();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != staking) revert Unauthorized();
        _burn(from, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            _allowances[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "to=0");
        uint256 bal = _balances[from];
        require(bal >= amount, "bal");
        unchecked {
            _balances[from] = bal - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
        if (from != address(0) && to != address(0) && amount > 0) {
            IShareStakingTransferHook(staking).onStakedSharesTransfer(from, to, amount);
        }
    }

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "to=0");
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        uint256 bal = _balances[from];
        require(bal >= amount, "bal");
        unchecked {
            _balances[from] = bal - amount;
            _totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }
}
