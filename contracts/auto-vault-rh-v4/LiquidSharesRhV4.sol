// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ILiquidSharesRhV4.sol";

/// @title LiquidSharesRhV4
/// @notice Cloneable share token; `initialize` sets vault + metadata (OZ ERC20 constructor does not run on clones).
contract LiquidSharesRhV4 is Ownable, ILiquidSharesRhV4 {
    string private _name;
    string private _symbol;
    uint8 private constant _decimals = 18;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    address public vault;
    address public immutable factory;
    bool public initialized;

    error Unauthorized();
    error ZeroAddress();
    error AlreadyInitialized();
    error InsufficientAllowance();
    error InsufficientBalance();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Implementation sets immutable `factory` (copied into EIP-1167 clones).
    constructor(address factory_) Ownable(msg.sender) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    function initialize(address vault_, string memory name_, string memory symbol_) public override {
        if (initialized) revert AlreadyInitialized();
        if (msg.sender != factory) revert Unauthorized();
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        _name = name_;
        _symbol = symbol_;
        initialized = true;
        _transferOwnership(vault_);
    }

    function bootstrap(address vault_) external override {
        initialize(vault_, "Liquid Shares", "aLS");
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

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function mint(address to, uint256 amount) external override {
        if (msg.sender != vault) revert Unauthorized();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external override {
        if (msg.sender != vault) revert Unauthorized();
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
            if (allowed < amount) revert InsufficientAllowance();
            _allowances[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = _balances[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            _balances[from] = bal - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        uint256 bal = _balances[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            _balances[from] = bal - amount;
            _totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }
}
