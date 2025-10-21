// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @author javierpmateos
 * @notice Evolved version with multi-token support, USD limits via Chainlink, and role-based access
 * @dev Extends KipuBank with ERC20 tokens, Chainlink price feeds, and OpenZeppelin security patterns
 * @custom:educational This contract is for educational purposes only and should not be used in production
 * @custom:security-contact sec***@gmail.com
 * @custom:idioma Lo pongo en inglés porque es buena práctica, ya tuve problemas con la ñ :)
 */
 
contract KipuBankV2 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*///////////////////////////////////
          Type declarations
    ///////////////////////////////////*/

    /// @notice Token configuration with price feed info
    struct TokenConfig {
        bool isSupported;
        uint8 decimals;
        AggregatorV3Interface priceFeed;
    }

    /*///////////////////////////////////
           State variables
    ///////////////////////////////////*/

    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // Constants - usamos 6 decimales (formato USDC) para toda la contabilidad interna
    uint8 private constant USDC_DECIMALS = 6;
    address private constant NATIVE_TOKEN = address(0); // address(0) = ETH
    uint256 private constant MAX_PRICE_AGE = 1 hours;

    /// @notice Max withdrawal per transaction in USD (6 decimals)
    uint256 public immutable i_withdrawalLimitUSD;
    
    /// @notice Max total bank capacity in USD (6 decimals)
    uint256 public immutable i_bankCapUSD;
    
    /// @notice Total deposits tracked in USD (6 decimals)
    uint256 public s_totalDepositsUSD;
    
    /// @notice Total deposit count
    uint256 public s_depositCount;
    
    /// @notice Total withdrawal count
    uint256 public s_withdrawalCount;
    
    /// @notice Nested mapping: user => token => balance (in token's native decimals)
    mapping(address => mapping(address => uint256)) public s_vaults;
    
    /// @notice Token configurations
    mapping(address => TokenConfig) public s_tokenConfigs;
    
    /// @notice Supported token list for iteration
    address[] public s_supportedTokens;

    /*///////////////////////////////////
               Events
    ///////////////////////////////////*/
    
    event Deposit(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 valueUSD,
        uint256 newBalance
    );
    
    event Withdrawal(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 valueUSD,
        uint256 newBalance
    );
    
    event TokenAdded(address indexed token, address indexed priceFeed, uint8 decimals);
    event TokenRemoved(address indexed token);
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);

    /*///////////////////////////////////
               Errors
    ///////////////////////////////////*/
    
    error ZeroAmountNotAllowed();
    error BankCapacityExceeded();
    error InsufficientVaultBalance();
    error WithdrawalLimitExceeded();
    error TransferFailed();
    error TokenNotSupported();
    error TokenAlreadySupported();
    error InvalidPriceFeed();
    error StalePrice();
    error InvalidPrice();
    error ZeroAddress();

    /*///////////////////////////////////
            Modifiers
    ///////////////////////////////////*/
    
    modifier validAmount(uint256 _amount) {
        if (_amount == 0) revert ZeroAmountNotAllowed();
        _;
    }
    
    modifier supportedToken(address _token) {
        if (!s_tokenConfigs[_token].isSupported) revert TokenNotSupported();
        _;
    }

    /*///////////////////////////////////
            Functions
    ///////////////////////////////////*/

    /*/////////////////////////
        constructor
    /////////////////////////*/
    
    /**
     * @notice Initialize KipuBankV2 with USD-based limits and ETH price feed
     * @param _withdrawalLimitUSD Max withdrawal per tx in USD (6 decimals)
     * @param _bankCapUSD Max total capacity in USD (6 decimals)
     * @param _ethPriceFeed Chainlink ETH/USD price feed address
     */
    constructor(
        uint256 _withdrawalLimitUSD,
        uint256 _bankCapUSD,
        address _ethPriceFeed
    ) {
        if (_ethPriceFeed == address(0)) revert ZeroAddress();
        
        i_withdrawalLimitUSD = _withdrawalLimitUSD;
        i_bankCapUSD = _bankCapUSD;
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        
        // Add native ETH support (18 decimals)
        _addToken(NATIVE_TOKEN, _ethPriceFeed, 18);
    }

    /*/////////////////////////
     Receive & Fallback
    /////////////////////////*/
    
    /**
     * @notice Receive ETH directly and deposit to sender's vault
     */
    receive() external payable {
        if (msg.value == 0) revert ZeroAmountNotAllowed();
        _deposit(NATIVE_TOKEN, msg.value);
    }
    
    /**
     * @notice Reject any other calls
     */
    fallback() external payable {
        revert();
    }

    /*/////////////////////////
        external
    /////////////////////////*/
    
    /**
     * @notice Deposit native ETH
     */
    function depositETH() external payable validAmount(msg.value) nonReentrant {
        _deposit(NATIVE_TOKEN, msg.value);
    }
    
    /**
     * @notice Deposit ERC20 tokens
     * @param _token Token address
     * @param _amount Amount in token decimals
     */
    function depositToken(address _token, uint256 _amount) 
        external 
        validAmount(_amount) 
        supportedToken(_token) 
        nonReentrant 
    {
        if (_token == NATIVE_TOKEN) revert TokenNotSupported();
        
        // Transfer tokens first (interactions before effects is ok here due to SafeERC20)
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        
        _deposit(_token, _amount);
    }
    
    /**
     * @notice Withdraw native ETH
     * @param _amount Amount in wei
     */
    function withdrawETH(uint256 _amount) 
        external 
        validAmount(_amount) 
        nonReentrant 
    {
        _withdraw(NATIVE_TOKEN, _amount);
        
        // Transfer ETH last (CEI pattern)
        (bool success, ) = payable(msg.sender).call{value: _amount}("");
        if (!success) revert TransferFailed();
    }
    
    /**
     * @notice Withdraw ERC20 tokens
     * @param _token Token address
     * @param _amount Amount in token decimals
     */
    function withdrawToken(address _token, uint256 _amount) 
        external 
        validAmount(_amount) 
        supportedToken(_token) 
        nonReentrant 
    {
        if (_token == NATIVE_TOKEN) revert TokenNotSupported();
        
        _withdraw(_token, _amount);
        
        // Transfer last
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }
    
    /**
     * @notice Add new token support (admin only)
     * @param _token Token address (address(0) for ETH)
     * @param _priceFeed Chainlink price feed (TOKEN/USD)
     * @param _decimals Token decimals
     */
    function addToken(address _token, address _priceFeed, uint8 _decimals) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        _addToken(_token, _priceFeed, _decimals);
    }
    
    /**
     * @notice Remove token support (admin only)
     * @param _token Token to remove
     * @dev Cannot remove native ETH
     */
    function removeToken(address _token) external onlyRole(ADMIN_ROLE) {
        if (!s_tokenConfigs[_token].isSupported) revert TokenNotSupported();
        if (_token == NATIVE_TOKEN) revert TokenNotSupported();
        
        s_tokenConfigs[_token].isSupported = false;
        
        // Remove from array
        for (uint256 i = 0; i < s_supportedTokens.length; i++) {
            if (s_supportedTokens[i] == _token) {
                s_supportedTokens[i] = s_supportedTokens[s_supportedTokens.length - 1];
                s_supportedTokens.pop();
                break;
            }
        }
        
        emit TokenRemoved(_token);
    }
    
    /**
     * @notice Emergency withdrawal (admin only)
     * @param _token Token to withdraw
     * @param _to Recipient
     * @param _amount Amount to withdraw
     */
    function emergencyWithdraw(address _token, address _to, uint256 _amount) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        if (_to == address(0)) revert ZeroAddress();
        
        if (_token == NATIVE_TOKEN) {
            (bool success, ) = payable(_to).call{value: _amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
        
        emit EmergencyWithdrawal(_token, _to, _amount);
    }

    /*/////////////////////////
         public
    /////////////////////////*/

    /*/////////////////////////
        internal
    /////////////////////////*/
    
    /**
     * @notice Internal deposit logic
     * @dev Converts to USD, checks capacity, updates state
     */
    function _deposit(address _token, uint256 _amount) internal supportedToken(_token) {
        uint256 valueUSD = _convertToUSD(_token, _amount);
        
        // Checks
        if (s_totalDepositsUSD + valueUSD > i_bankCapUSD) {
            revert BankCapacityExceeded();
        }
        
        // Effects
        s_vaults[msg.sender][_token] += _amount;
        s_totalDepositsUSD += valueUSD;
        s_depositCount++;
        
        emit Deposit(msg.sender, _token, _amount, valueUSD, s_vaults[msg.sender][_token]);
    }
    
    /**
     * @notice Internal withdrawal logic
     * @dev Checks balance and USD limit, updates state
     */
    function _withdraw(address _token, uint256 _amount) internal supportedToken(_token) {
        // Checks
        if (_amount > s_vaults[msg.sender][_token]) {
            revert InsufficientVaultBalance();
        }
        
        uint256 valueUSD = _convertToUSD(_token, _amount);
        if (valueUSD > i_withdrawalLimitUSD) {
            revert WithdrawalLimitExceeded();
        }
        
        // Effects
        s_vaults[msg.sender][_token] -= _amount;
        s_totalDepositsUSD -= valueUSD;
        s_withdrawalCount++;
        
        emit Withdrawal(msg.sender, _token, _amount, valueUSD, s_vaults[msg.sender][_token]);
    }

    /*/////////////////////////
        private
    /////////////////////////*/
    
    /**
     * @notice Add token to supported list
     * @dev Validates price feed before adding
     */
    function _addToken(address _token, address _priceFeed, uint8 _decimals) private {
        if (s_tokenConfigs[_token].isSupported) revert TokenAlreadySupported();
        if (_priceFeed == address(0)) revert InvalidPriceFeed();
        
        // Check if price feed works
        AggregatorV3Interface feed = AggregatorV3Interface(_priceFeed);
        try feed.latestRoundData() returns (uint80, int256, uint256, uint256, uint80) {
            // Price feed is valid
        } catch {
            revert InvalidPriceFeed();
        }
        
        s_tokenConfigs[_token] = TokenConfig({
            isSupported: true,
            decimals: _decimals,
            priceFeed: feed
        });
        
        s_supportedTokens.push(_token);
        
        emit TokenAdded(_token, _priceFeed, _decimals);
    }
    
    /**
     * @notice Convert token amount to USD value
     * @dev Uses Chainlink price feed and normalizes to 6 decimals
     * @param _token Token address
     * @param _amount Amount in token decimals
     * @return USD value with 6 decimals
     */
    function _convertToUSD(address _token, uint256 _amount) private view returns (uint256) {
        TokenConfig memory config = s_tokenConfigs[_token];
        
        // Get price from Chainlink
        (, int256 price, , uint256 updatedAt, ) = config.priceFeed.latestRoundData();
        
        // Basic validation
        if (price <= 0) revert InvalidPrice();
        if (updatedAt < block.timestamp - MAX_PRICE_AGE) revert StalePrice();
        
        uint8 priceFeedDecimals = config.priceFeed.decimals();
        
        // Formula: (amount * price) / 10^(tokenDecimals + priceDecimals - USDC_DECIMALS)
        // Esto normaliza todo a 6 decimales (formato USDC)
        uint256 valueUSD = (_amount * uint256(price)) / 
            (10 ** (config.decimals + priceFeedDecimals - USDC_DECIMALS));
        
        return valueUSD;
    }

    /*/////////////////////////
      View & Pure
    /////////////////////////*/
    
    /**
     * @notice Get vault balance for user and token
     * @param _user User address
     * @param _token Token address
     * @return Balance in token decimals
     */
    function getVaultBalance(address _user, address _token) external view returns (uint256) {
        return s_vaults[_user][_token];
    }
    
    /**
     * @notice Get total USD value for a user across all tokens
     * @param _user User address
     * @return Total value in USD (6 decimals)
     */
    function getUserTotalValueUSD(address _user) external view returns (uint256) {
        uint256 totalUSD = 0;
        
        for (uint256 i = 0; i < s_supportedTokens.length; i++) {
            address token = s_supportedTokens[i];
            uint256 balance = s_vaults[_user][token];
            
            if (balance > 0) {
                totalUSD += _convertToUSD(token, balance);
            }
        }
        
        return totalUSD;
    }
    
    /**
     * @notice Get comprehensive bank info
     */
    function getBankInfo() 
        external 
        view 
        returns (
            uint256 _totalDepositsUSD,
            uint256 _bankCapUSD,
            uint256 _withdrawalLimitUSD,
            uint256 _depositCount,
            uint256 _withdrawalCount,
            uint256 _supportedTokenCount
        ) 
    {
        return (
            s_totalDepositsUSD,
            i_bankCapUSD,
            i_withdrawalLimitUSD,
            s_depositCount,
            s_withdrawalCount,
            s_supportedTokens.length
        );
    }
    
    /**
     * @notice Get all supported tokens
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return s_supportedTokens;
    }
    
    /**
     * @notice Get token config
     */
    function getTokenConfig(address _token) external view returns (TokenConfig memory) {
        return s_tokenConfigs[_token];
    }
    
    /**
     * @notice Convert token amount to USD (public helper)
     */
    function convertToUSD(address _token, uint256 _amount) 
        external 
        view 
        supportedToken(_token) 
        returns (uint256) 
    {
        return _convertToUSD(_token, _amount);
    }
    
    /**
     * @notice Get current token price from Chainlink
     */
    function getTokenPrice(address _token) 
        external 
        view 
        supportedToken(_token) 
        returns (int256 price, uint8 decimals) 
    {
        TokenConfig memory config = s_tokenConfigs[_token];
        (, price, , , ) = config.priceFeed.latestRoundData();
        decimals = config.priceFeed.decimals();
    }
}
