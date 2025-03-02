// SPDX-License-Identifier: MIT
pragma solidity >0.8.26 <=0.9.0;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title Advanced Presale Contract with IPFS Metadata
 * @notice Manages token presales with decentralized metadata storage
 * @dev Integrates IPFS for transparent documentation storage
 */
contract Presale is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address payable;

    /// @notice Scaling factor for precision calculations
    uint256 public constant SCALE = 10**18;
    
    /// @notice Total number of vesting stages
    uint256 public constant VESTING_STAGES = 10;
    
    /// @notice Total vesting duration in seconds (3 years)
    uint256 public constant VESTING_DURATION = 3 * 365 days;
    
    /// @notice Duration of each vesting stage in seconds
    uint256 public constant STAGE_DURATION = VESTING_DURATION / VESTING_STAGES;

    /// @notice Slippage tolerance for liquidity addition (basis points)
    uint256 public slippageBps = 500;

    /// @notice IPFS CIDv1 for presale metadata
    string public ipfsCID;

    /// @notice Timestamp of metadata publication
    uint256 public ipfsPublishDate;

    /**
     * @notice Presale configuration parameters
     * @param tokenDeposit Total tokens deposited (sale + liquidity)
     * @param hardCap Maximum BNB to raise (in wei)
     * @param softCap Minimum BNB for success (in wei)
     * @param max Maximum contribution per address
     * @param min Minimum contribution per address
     * @param start Presale start timestamp
     * @param end Presale end timestamp
     * @param liquidityBps Percentage of funds for liquidity (basis points)
     */
    struct PresaleOptions {
        uint256 tokenDeposit;
        uint256 hardCap;
        uint256 softCap;
        uint256 max;
        uint256 min;
        uint64 start;
        uint64 end;
        uint32 liquidityBps;
    }

    /**
     * @notice Vesting schedule for participant
     * @param totalAllocated Total tokens allocated (adjusted for decimals)
     * @param claimed Tokens already claimed
     */
    struct VestingSchedule {
        uint256 totalAllocated;
        uint256 claimed;
    }

    /**
     * @notice Presale state container
     * @param token ERC20 token contract
     * @param pancakeRouter PancakeSwap router interface
     * @param tokenBalance Current token balance in contract
     * @param tokensClaimable Tokens allocated for presale participants
     * @param tokensLiquidity Tokens reserved for liquidity pool
     * @param weiRaised Total BNB raised (in wei)
     * @param wbnb WBNB contract address
     * @param state Current presale state
     * @param options Presale configuration
     */
    struct Pool {
        IERC20 token;
        IUniswapV2Router02 pancakeRouter;
        uint256 tokenBalance;
        uint256 tokensClaimable;
        uint256 tokensLiquidity;
        uint256 weiRaised;
        address wbnb;
        uint8 state;
        PresaleOptions options;
    }

    /// @notice Presale state constants
    uint8 private constant STATE_INITIALIZED = 1;
    uint8 private constant STATE_ACTIVE = 2;
    uint8 private constant STATE_CANCELED = 3;
    uint8 private constant STATE_FINALIZED = 4;

    /// @notice Main presale storage
    Pool public pool;

    /// @notice Vesting start timestamp
    uint256 public vestingStartTime;

    /// @notice Whitelist status mapping
    mapping(address => bool) public whitelist;
    
    /// @notice Whitelist enforcement flag
    bool public isWhitelistEnabled = false;

    /// @notice Participant contributions tracking
    mapping(address => uint256) public contributions;

    /// @notice Vesting schedules mapping
    mapping(address => VestingSchedule) public vestingSchedules;

    /// @notice Token decimals storage
    uint8 private immutable tokenDecimals;

    // Events
    event Deposit(address indexed creator, uint256 amount, uint256 timestamp);
    event Purchase(address indexed beneficiary, uint256 contribution);
    event Finalized(address indexed creator, uint256 amount, uint256 timestamp);
    event Refund(address indexed beneficiary, uint256 amount, uint256 timestamp);
    event TokenClaim(address indexed beneficiary, uint256 amount, uint256 timestamp);
    event Cancel(address indexed creator, uint256 timestamp);
    event WhitelistUpdated(address[] accounts, bool status);
    event SlippageUpdated(uint256 newSlippage);
    event IPFSParamsUpdated(string indexed cid, uint256 timestamp);

    // Errors
    error InvalidState(uint8 currentState);
    error SoftCapNotReached();
    error HardCapExceed();
    error NotClaimable();
    error NotInPurchasePeriod();
    error PurchaseBelowMinimum();
    error PurchaseLimitExceed();
    error NotRefundable();
    error LiquificationFailed();
    error InvalidCapValue();
    error InvalidLimitValue();
    error InvalidTimestampValue();
    error InvalidLiquidityValue();
    error FrontrunProtection();
    error InvalidInitializationParams();

    /**
     * @dev Modifier for refundable states
     */
    modifier onlyRefundable() {
        bool canRefund = (
            pool.state == STATE_CANCELED ||
            (block.timestamp > pool.options.end && pool.weiRaised < pool.options.softCap)
        );
        if (!canRefund) revert NotRefundable();
        _;
    }

    /**
     * @notice Initializes presale contract with IPFS metadata
     * @param _wbnb WBNB contract address
     * @param _token ERC20 token address
     * @param _pancakeRouter PancakeSwap router address
     * @param _options Presale configuration parameters
     * @param _initialCID Initial IPFS CID for metadata (empty for none)
     */
    constructor(
        address _wbnb,
        address _token,
        address _pancakeRouter,
        PresaleOptions memory _options,
        string memory _initialCID
    ) Ownable(msg.sender) {
        _validatePoolConfig(_options);
        
        // Frontrun protection checks
        if (_options.start < block.timestamp + 1 hours) revert FrontrunProtection();
        if (_options.end - _options.start > 30 days) revert FrontrunProtection();

        pool.pancakeRouter = IUniswapV2Router02(_pancakeRouter);
        pool.token = IERC20(_token);
        pool.state = STATE_INITIALIZED;
        pool.wbnb = _wbnb;
        pool.options = _options;

        // Initialize IPFS params if provided
        if(bytes(_initialCID).length > 0) {
            ipfsCID = _initialCID;
            ipfsPublishDate = block.timestamp;
        }

        // Initialize token decimals
        tokenDecimals = _tryGetDecimals(_token);
    }

    /// @notice Accepts BNB contributions
    receive() external payable {
        _processPurchase(msg.sender, msg.value);
    }

    // ========================== USER FUNCTIONS ==========================

    /**
     * @notice Claims vested tokens according to schedule
     * @return amount Amount of tokens claimed
     */
    function claim() external nonReentrant returns (uint256) {
        require(pool.state == STATE_FINALIZED, "Presale not finalized");
        require(vestingStartTime != 0, "Vesting not started");

        VestingSchedule storage schedule = vestingSchedules[msg.sender];
        if (schedule.totalAllocated == 0) {
            uint256 totalTokens = calculateTokens(msg.sender);
            require(totalTokens > 0, "No tokens allocated");
            schedule.totalAllocated = totalTokens * 10 ** tokenDecimals;
        }

        uint256 claimable = _calculateClaimable(schedule);
        require(claimable > 0, "Nothing to claim");

        schedule.claimed += claimable;
        pool.tokenBalance -= claimable;
        SafeERC20.safeTransfer(pool.token, msg.sender, claimable);

        emit TokenClaim(msg.sender, claimable, block.timestamp);
        return claimable;
    }

    /**
     * @notice Processes refund for failed presale
     * @return amount Refund amount in BNB
     */
    function refund() external onlyRefundable nonReentrant returns (uint256) {
        if (contributions[msg.sender] == 0) revert NotRefundable();

        uint256 amount = contributions[msg.sender];
        contributions[msg.sender] = 0;

        payable(msg.sender).sendValue(amount);
        emit Refund(msg.sender, amount, block.timestamp);
        return amount;
    }

    // ========================== OWNER FUNCTIONS ==========================

    /**
     * @notice Updates IPFS metadata reference
     * @dev Emits IPFSParamsUpdated event
     * @param _cid New IPFS CIDv1 for metadata
     */
    function setIPFSParams(string calldata _cid) external onlyOwner {
        require(bytes(_cid).length == 46, "Invalid CID format");
        ipfsCID = _cid;
        ipfsPublishDate = block.timestamp;
        emit IPFSParamsUpdated(_cid, block.timestamp);
    }

    /**
     * @notice Deposits tokens and activates presale
     * @return depositedAmount Amount of tokens deposited
     */
    function deposit() external onlyOwner returns (uint256) {
        if (pool.state != STATE_INITIALIZED) revert InvalidState(pool.state);
        
        pool.state = STATE_ACTIVE;
        pool.tokensLiquidity = _calculateLiquidityTokens();
        pool.tokensClaimable = pool.options.tokenDeposit - pool.tokensLiquidity;

        if (pool.tokensClaimable == 0 || pool.tokensLiquidity == 0) {
            revert InvalidLiquidityValue();
        }

        pool.tokenBalance += pool.options.tokenDeposit;
        pool.token.safeTransferFrom(msg.sender, address(this), pool.options.tokenDeposit);
        
        emit Deposit(msg.sender, pool.options.tokenDeposit, block.timestamp);
        return pool.options.tokenDeposit;
    }

    /**
     * @notice Finalizes presale and initiates vesting period
     * @return success True if finalization succeeded
     */
    function finalize() external onlyOwner nonReentrant returns (bool) {
        if (pool.state != STATE_ACTIVE) revert InvalidState(pool.state);
        if (pool.weiRaised < pool.options.softCap && block.timestamp < pool.options.end) {
            revert SoftCapNotReached();
        }

        pool.state = STATE_FINALIZED;
        vestingStartTime = block.timestamp;

        // Add liquidity with slippage protection
        uint256 liquidityWei = (pool.weiRaised * pool.options.liquidityBps) / 10000;
        _addLiquidity(liquidityWei, pool.tokensLiquidity);
        
        // Transfer remaining BNB to owner
        uint256 remainingWei = pool.weiRaised - liquidityWei;
        if (remainingWei > 0) {
            payable(owner()).sendValue(remainingWei);
        }

        emit Finalized(msg.sender, pool.weiRaised, block.timestamp);
        return true;
    }

    /**
     * @notice Cancels presale and enables refunds
     * @return success True if cancellation succeeded
     */
    function cancel() external onlyOwner returns (bool) {
        if (pool.state >= STATE_CANCELED) revert InvalidState(pool.state);

        pool.state = STATE_CANCELED;
        if (pool.tokenBalance > 0) {
            uint256 amount = pool.tokenBalance;
            pool.tokenBalance = 0;
            pool.token.safeTransfer(owner(), amount);
        }

        emit Cancel(msg.sender, block.timestamp);
        return true;
    }

    // ========================== VIEW FUNCTIONS ==========================

    /**
     * @notice Generates IPFS gateway URL for metadata
     * @return url Full IPFS gateway URL
     */
    function getIPFSMetadataURL() external view returns (string memory) {
        return string(abi.encodePacked("ipfs://", ipfsCID));
    }

    /**
     * @notice Calculates claimable tokens for address
     * @param contributor Participant's address
     * @return amount Currently claimable tokens
     */
    function availableToClaim(address contributor) public view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[contributor];
        if (schedule.totalAllocated == 0) return 0;
        return _calculateClaimable(schedule);
    }

    /**
     * @notice Calculates total token allocation for address
     * @param contributor Participant's address
     * @return amount Total allocated tokens (not adjusted for decimals)
     */
    function calculateTokens(address contributor) public view returns (uint256) {
        if (pool.weiRaised == 0) return 0;
        return (contributions[contributor] * pool.tokensClaimable) / pool.weiRaised;
    }

    // ========================== INTERNAL FUNCTIONS ==========================

    /**
     * @dev Processes purchase with validation
     * @param buyer Contributor address
     * @param amount BNB contribution amount
     */
    function _processPurchase(address buyer, uint256 amount) internal nonReentrant {
        _validatePurchase(buyer, amount);
        pool.weiRaised += amount;
        contributions[buyer] += amount;
        emit Purchase(buyer, amount);
    }

    /**
     * @dev Adds liquidity to DEX with slippage protection
     * @param _bnbAmount BNB amount for liquidity
     * @param _tokenAmount Token amount for liquidity
     */
    function _addLiquidity(uint256 _bnbAmount, uint256 _tokenAmount) private {
        // Calculate minimum amounts with slippage tolerance
        uint256 minToken = (_tokenAmount * (10000 - slippageBps)) / 10000;
        uint256 minBNB = (_bnbAmount * (10000 - slippageBps)) / 10000;

        (uint amountToken, uint amountBNB, ) = pool.pancakeRouter.addLiquidityETH{value: _bnbAmount}(
            address(pool.token),
            _tokenAmount,
            minToken,
            minBNB,
            owner(),
            block.timestamp + 600
        );
        
        // Validate against minimums
        if (amountToken < minToken || amountBNB < minBNB) {
            revert LiquificationFailed();
        }

        // Return excess tokens
        if (_tokenAmount > amountToken) {
            uint256 excess = _tokenAmount - amountToken;
            pool.token.safeTransfer(owner(), excess);
            pool.tokenBalance -= excess;
        }
    }

    /**
     * @dev Calculates claimable tokens for vesting schedule
     * @param schedule Vesting schedule reference
     * @return claimable Currently claimable tokens
     */
    function _calculateClaimable(VestingSchedule storage schedule) internal view returns (uint256) {
        if (vestingStartTime == 0) return 0;
        
        uint256 elapsed = block.timestamp - vestingStartTime;
        uint256 completedStages = elapsed / STAGE_DURATION;
        
        completedStages = completedStages > VESTING_STAGES 
            ? VESTING_STAGES 
            : completedStages;

        uint256 unlocked = (schedule.totalAllocated * completedStages) / VESTING_STAGES;
        return unlocked - schedule.claimed;
    }

    /**
     * @dev Validates presale configuration
     * @param opts Presale options
     */
    function _validatePoolConfig(PresaleOptions memory opts) internal pure {
        if (opts.liquidityBps > 9000) revert InvalidLiquidityValue();
        if (opts.softCap > opts.hardCap) revert InvalidCapValue();
        if (opts.min > opts.max) revert InvalidLimitValue();
        if (opts.start >= opts.end) revert InvalidTimestampValue();
        if (opts.tokenDeposit == 0) revert InvalidInitializationParams();
    }

    /**
     * @dev Safely retrieves token decimals
     * @param tokenAddress ERC20 token address
     * @return decimals Token decimals
     */
    function _tryGetDecimals(address tokenAddress) private view returns (uint8) {
        try IERC20Metadata(tokenAddress).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18;
        }
    }

    /**
     * @dev Calculates tokens allocated for liquidity
     * @return liquidityTokens Token amount for liquidity pool
     */
    function _calculateLiquidityTokens() internal view returns (uint256) {
        return (pool.options.tokenDeposit * pool.options.liquidityBps) / 10000;
    }

    /**
     * @dev Validates purchase parameters
     * @param buyer Contributor address
     * @param amount BNB contribution amount
     */
    function _validatePurchase(address buyer, uint256 amount) internal view {
        if (pool.state != STATE_ACTIVE) revert InvalidState(pool.state);
        if (block.timestamp < pool.options.start || block.timestamp > pool.options.end) {
            revert NotInPurchasePeriod();
        }
        if (amount < pool.options.min) revert PurchaseBelowMinimum();
        if (contributions[buyer] + amount > pool.options.max) revert PurchaseLimitExceed();
        if (pool.weiRaised + amount > pool.options.hardCap) revert HardCapExceed();
        if (isWhitelistEnabled && !whitelist[buyer]) revert("Not whitelisted");
    }
}
