// SPDX-License-Identifier: MIT
pragma solidity >0.8.26 <=0.9.0;

/**
 * @title BEP20 Token Standard Interface
 * @dev Official interface for Binance Smart Chain's BEP20 standard
 * @notice Includes all required functions and events for BEP20 compliance
 */
interface IBEP20 {
    /**
     * @dev Returns the total token supply
     * @return Total circulating supply of tokens
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the token decimals
     * @return Number of decimals used for token divisions
     */
    function decimals() external view returns (uint8);

    /**
     * @dev Returns the token symbol
     * @return Token symbol as a string
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the token name
     * @return Token name as a string
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the bep token owner
     * @return Address of token owner
     */
    function getOwner() external view returns (address);

    /**
     * @dev Returns account balance
     * @param account Address to check balance for
     * @return Token balance of specified account
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Transfers tokens to a specified address
     * @param recipient Destination address
     * @param amount Amount to transfer
     * @return Boolean indicating operation success
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns remaining allowance for spender
     * @param owner Account providing allowance
     * @param spender Account using allowance
     * @return Remaining allowance amount
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Approves spender to transfer tokens
     * @param spender Beneficiary of allowance
     * @param amount Allowance amount
     * @return Boolean indicating operation success
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Transfers tokens using allowance mechanism
     * @param sender Source address
     * @param recipient Destination address
     * @param amount Amount to transfer
     * @return Boolean indicating operation success
     */
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    /// @notice Emitted when tokens are transferred
    event Transfer(address indexed from, address indexed to, uint256 value);
    
    /// @notice Emitted when allowance is approved
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

/**
 * @title Context Contract
 * @dev Provides information about current execution context
 * @notice Contains internal functions for context information retrieval
 */
contract Context {
    /**
     * @dev Empty constructor for abstract contracts
     */
    constructor () {}

    /**
     * @dev Returns message sender
     * @return Address of message sender
     */
    function _msgSender() internal view returns (address) {
        return msg.sender;
    }

    /**
     * @dev Returns message data
     * @return Raw bytes of message data
     */
    function _msgData() internal view returns (bytes memory) {
        this; // Silence state mutability warning
        return msg.data;
    }
}

/**
 * @title Ownable Contract
 * @dev Provides basic authorization control
 * @notice Allows specifying an owner address with transferable ownership
 */
contract Ownable is Context {
    address private _owner;
    
    /// @notice Emitted when ownership is transferred
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes contract with deployer as initial owner
     */
    constructor () {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns current owner address
     * @return Address of current owner
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by non-owner
     */
    modifier onlyOwner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves contract without owner
     * @notice Removes ownership permanently
     */
    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership to new address
     * @param newOwner Address of new owner
     */
    function transferOwnership(address newOwner) public onlyOwner {
        _transferOwnership(newOwner);
    }

    /**
     * @dev Internal ownership transfer implementation
     * @param newOwner Address of new owner
     */
    function _transferOwnership(address newOwner) internal {
        require(newOwner != address(0), "Ownable: new owner is zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/**
 * @title SDC Token Contract
 * @dev Comprehensive token contract with advanced features
 * @notice Combines BEP20 compliance with voting, staking, fee management and KYC systems
 */
contract SdcToken is Context, IBEP20, Ownable {
    /**
     * @dev Structure representing a voting participant
     * @notice Tracks voting weight and delegation status
     */
    struct Voter {
        uint256 weight;     // Voting power based on available balance
        bool voted;         // Flag indicating voting completion
        address delegate;  // Delegated voting address
        uint256 vote;       // Index of chosen proposal
    }

    /**
     * @dev Structure representing a governance proposal
     * @notice Contains proposal metadata and voting status
     */
    struct Proposal {
        bytes32 name;       // Short proposal identifier
        uint256 voteCount;  // Accumulated votes count
        bytes32 ipfsHash;   // IPFS CID for proposal details
    }

    /**
     * @dev Structure representing a token stake
     * @notice Tracks staked amounts and reward parameters
     */
    struct Stake {
        uint256 amount;         // Staked token quantity
        uint256 startTimestamp; // Stake initiation time
        uint256 duration;       // Lock-up period in seconds
        uint256 rewardRate;     // Annual Percentage Rate (APR)
        bool claimed;           // Withdrawal status flag
    }

    /**
     * @dev Structure representing APR promotion slot
     * @notice Defines parameters for guaranteed return periods
     */
    struct APRSlot {
        uint256 id;         // Unique slot identifier
        uint256 apr;        // Fixed APR percentage
        uint256 minAmount;  // Minimum stake requirement
        uint256 maxAmount;  // Maximum stake limit
        uint256 startTime;  // Slot activation timestamp
        uint256 endTime;    // Slot expiration timestamp
        bool active;        // Slot availability status
    }

    // Token Metadata
    string private _name = "Sign Documents Chain";
    string private _symbol = "SDC";
    uint8 private _decimals = 18;
    uint256 private _totalSupply = 50_000_000 * (10**18);

    // Token State
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // Governance System
    Proposal[] public proposals;
    mapping(address => Voter) public voters;
    uint256 public minVotingBalance = 1 ether;
    address public votingManager;
    bool public votingEnabled = true;

    // Fee System
    address private _feeWallet1;
    address private _feeWallet2;
    uint256 private _feePercentage;  // Basis points (1% = 100)
    uint256 private _feeSplitRatio;  // Basis points (70% = 7000)
    uint256 public constant MAX_FEE = 10000;

    // Staking System
    mapping(address => Stake[]) private _stakes;
    uint256 public minStakeDuration = 1 days;
    uint256 public maxStakeDuration = 365 days;
    uint256 public earlyUnstakePenalty = 3000; // 30% penalty
    uint256 public maxAPR = 5000; // 50% maximum APR

    // KYC System
    uint256 public kycThreshold = 10000 * (10**18);
    mapping(address => bool) private _kycVerified;

    // APR Slot System
    APRSlot[] public aprSlots;
    mapping(uint256 => mapping(address => uint256)) public slotStakes;

    // Events
    event FeeConfigUpdated(uint256 timestamp, address feeWallet1, address feeWallet2, uint256 feePercentage, uint256 splitRatio);
    event VotingConfigUpdated(uint256 timestamp, string configType, address updater);
    event Staked(address indexed user, uint256 amount, uint256 duration);
    event Unstaked(address indexed user, uint256 amount, uint256 reward, bool early);
    event APRConfigUpdated(uint256 newMaxAPR, uint256 newPenalty);
    event KYCVerified(address indexed user);
    event APRSlotCreated(uint256 slotId);
    event APRSlotUpdated(uint256 slotId);
    event SlotStaked(address indexed user, uint256 slotId, uint256 amount);

    /**
     * @dev Initializes token contract with core parameters
     * @param proposalNames Initial governance proposals
     * @param feeWallet1 Primary fee collection address
     * @param feeWallet2 Secondary fee collection address
     * @param initialFee Initial transaction fee percentage
     * @param initialSplit Initial fee distribution ratio
     * @notice Deploys initial supply to contract deployer
     */
    constructor(
        bytes32[] memory proposalNames,
        address feeWallet1,
        address feeWallet2,
        uint256 initialFee,
        uint256 initialSplit
    ) {
        require(feeWallet1 != address(0) && feeWallet2 != address(0), "Invalid fee wallets");
        require(initialFee <= MAX_FEE && initialSplit <= MAX_FEE, "Invalid fee parameters");

        _balances[msg.sender] = _totalSupply;
        _feeWallet1 = feeWallet1;
        _feeWallet2 = feeWallet2;
        _feePercentage = initialFee;
        _feeSplitRatio = initialSplit;

        // Initialize governance proposals
        for (uint256 i = 0; i < proposalNames.length; i++) {
            proposals.push(Proposal({
                name: proposalNames[i],
                voteCount: 0,
                ipfsHash: bytes32(0)
            }));
        }

        emit Transfer(address(0), msg.sender, _totalSupply);
    }

    // --------------------------
    // BEP20 Core Implementation
    // --------------------------

    /**
     * @dev Returns contract owner address
     * @return Address of contract owner
     */
    function getOwner() external view override returns (address) {
        return owner();
    }

    /**
     * @dev Returns token decimals
     * @return Number of decimal places
     */
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /**
     * @dev Returns token symbol
     * @return Token symbol string
     */
    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns token name
     * @return Token name string
     */
    function name() external view override returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns total token supply
     * @return Total number of minted tokens
     */
    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev Returns account balance
     * @param account Address to check balance for
     * @return Token balance of specified account
     */
    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev Returns remaining allowance
     * @param owner Allowance provider address
     * @param spender Allowance spender address
     * @return Remaining allowance amount
     */
    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev Approves token allowance
     * @param spender Spender address
     * @param amount Allowance amount
     * @return Boolean indicating success
     */
    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    // --------------------------
    // Transfer System Implementation
    // --------------------------

    /**
     * @dev Executes token transfer with fee calculation
     * @param recipient Destination address
     * @param amount Transfer amount
     * @return Boolean indicating success
     */
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transferWithFee(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev Executes allowance-based transfer with fee calculation
     * @param sender Source address
     * @param recipient Destination address
     * @param amount Transfer amount
     * @return Boolean indicating success
     */
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transferWithFee(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()] - amount);
        return true;
    }

    /**
     * @dev Internal transfer with fee deduction
     * @param sender Source address
     * @param recipient Destination address
     * @param amount Transfer amount
     */
    function _transferWithFee(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "Transfer from zero address");
        require(recipient != address(0), "Transfer to zero address");
        require(amount > 0, "Invalid transfer amount");

        uint256 feeAmount = 0;
        if (_feePercentage > 0) {
            feeAmount = (amount * _feePercentage) / MAX_FEE;
            require(amount > feeAmount, "Fee exceeds amount");

            uint256 fee1 = (feeAmount * _feeSplitRatio) / MAX_FEE;
            uint256 fee2 = feeAmount - fee1;
            
            _transfer(sender, _feeWallet1, fee1);
            _transfer(sender, _feeWallet2, fee2);
        }

        uint256 transferAmount = amount - feeAmount;
        _transfer(sender, recipient, transferAmount);
    }

    /**
     * @dev Internal transfer implementation
     * @param from Source address
     * @param to Destination address
     * @param amount Transfer amount
     */
    function _transfer(address from, address to, uint256 amount) internal {
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }

    // --------------------------
    // Fee System Implementation
    // --------------------------

    /**
     * @dev Updates fee parameters
     * @param newFee New transaction fee percentage
     * @param newSplit New fee distribution ratio
     */
    function setFeeConfig(uint256 newFee, uint256 newSplit) external onlyOwner {
        require(newFee <= MAX_FEE && newSplit <= MAX_FEE, "Invalid parameters");
        _feePercentage = newFee;
        _feeSplitRatio = newSplit;
        emit FeeConfigUpdated(block.timestamp, _feeWallet1, _feeWallet2, newFee, newSplit);
    }

    /**
     * @dev Updates fee collection wallets
     * @param newWallet1 New primary fee wallet
     * @param newWallet2 New secondary fee wallet
     */
    function setFeeWallets(address newWallet1, address newWallet2) external onlyOwner {
        require(newWallet1 != address(0) && newWallet2 != address(0), "Invalid wallets");
        _feeWallet1 = newWallet1;
        _feeWallet2 = newWallet2;
        emit FeeConfigUpdated(block.timestamp, newWallet1, newWallet2, _feePercentage, _feeSplitRatio);
    }

    /**
     * @dev Returns current fee configuration
     * @return feeWallet1 Primary fee wallet
     * @return feeWallet2 Secondary fee wallet
     * @return feePercentage Current fee percentage
     * @return splitRatio Current split ratio
     */
    function getFeeConfig() external view returns (
        address feeWallet1,
        address feeWallet2,
        uint256 feePercentage,
        uint256 splitRatio
    ) {
        return (_feeWallet1, _feeWallet2, _feePercentage, _feeSplitRatio);
    }

    // --------------------------
    // Governance System Implementation
    // --------------------------

    /**
     * @dev Updates voting manager address
     * @param newManager New voting manager address
     */
    function setVotingManager(address newManager) external onlyOwner {
        votingManager = newManager;
        emit VotingConfigUpdated(block.timestamp, "VotingManager", msg.sender);
    }

    /**
     * @dev Toggles voting system status
     * @param enabled New voting system state
     */
    function setVotingEnabled(bool enabled) external onlyVotingAdmin {
        votingEnabled = enabled;
        emit VotingConfigUpdated(block.timestamp, "VotingEnabled", msg.sender);
    }

    /**
     * @dev Updates minimum voting balance
     * @param newMinBalance New minimum balance required
     */
    function setMinVotingBalance(uint256 newMinBalance) external onlyVotingAdmin {
        minVotingBalance = newMinBalance;
        emit VotingConfigUpdated(block.timestamp, "MinVotingBalance", msg.sender);
    }

    // --------------------------
    // Staking System Implementation
    // --------------------------

    /**
     * @dev Stakes tokens for rewards
     * @param amount Amount to stake
     * @param duration Lock-up period in seconds
     */
    function stake(uint256 amount, uint256 duration) external {
        require(amount > 0, "Cannot stake zero");
        require(duration >= minStakeDuration && duration <= maxStakeDuration, "Invalid duration");
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        if (amount >= kycThreshold) require(_kycVerified[msg.sender], "KYC required");

        _balances[msg.sender] -= amount;
        _balances[address(this)] += amount;
        
        uint256 rewardRate = (maxAPR * duration) / maxStakeDuration;
        rewardRate = rewardRate > maxAPR ? maxAPR : rewardRate;
        
        _stakes[msg.sender].push(Stake({
            amount: amount,
            startTimestamp: block.timestamp,
            duration: duration,
            rewardRate: rewardRate,
            claimed: false
        }));

        voters[msg.sender].weight = _balances[msg.sender];
        emit Staked(msg.sender, amount, duration);
    }

    /**
     * @dev Withdraws staked tokens with rewards
     * @param stakeIndex Index of stake in user's stakes array
     */
    function unstake(uint256 stakeIndex) external {
        require(stakeIndex < _stakes[msg.sender].length, "Invalid index");
        Stake storage stakeData = _stakes[msg.sender][stakeIndex];
        require(!stakeData.claimed, "Already claimed");

        uint256 reward = calculateReward(stakeData);
        uint256 total = stakeData.amount + reward;
        bool early = block.timestamp < stakeData.startTimestamp + stakeData.duration;

        if (early) {
            uint256 penalty = (total * earlyUnstakePenalty) / 10000;
            total -= penalty;
        }

        stakeData.claimed = true;
        _balances[address(this)] -= stakeData.amount;
        _balances[msg.sender] += total;

        voters[msg.sender].weight = _balances[msg.sender];
        emit Unstaked(msg.sender, stakeData.amount, reward, early);
    }

    /**
     * @dev Calculates reward for given stake
     * @param stakeData Stake information
     * @return Calculated reward amount
     */
    function calculateReward(Stake memory stakeData) public view returns (uint256) {
        uint256 elapsed = block.timestamp - stakeData.startTimestamp;
        uint256 effective = elapsed > stakeData.duration ? stakeData.duration : elapsed;
        return (stakeData.amount * stakeData.rewardRate * effective) / (10000 * 365 days);
    }

    // --------------------------
    // APR Slot System Implementation
    // --------------------------

    /**
     * @dev Creates new APR promotion slot
     * @param apr Fixed APR percentage
     * @param minAmount Minimum stake amount
     * @param maxAmount Maximum stake amount
     * @param durationDays Slot duration in days
     */
    function createAPRSlot(
        uint256 apr,
        uint256 minAmount,
        uint256 maxAmount,
        uint256 durationDays
    ) external onlyOwner {
        require(apr <= maxAPR, "APR exceeds maximum");
        aprSlots.push(APRSlot({
            id: aprSlots.length,
            apr: apr,
            minAmount: minAmount,
            maxAmount: maxAmount,
            startTime: block.timestamp,
            endTime: block.timestamp + durationDays * 1 days,
            active: true
        }));
        emit APRSlotCreated(aprSlots.length - 1);
    }

    /**
     * @dev Stakes tokens in APR promotion slot
     * @param slotId ID of APR slot
     * @param amount Amount to stake
     */
    function stakeInSlot(uint256 slotId, uint256 amount) external {
        require(slotId < aprSlots.length, "Invalid slot");
        APRSlot storage slot = aprSlots[slotId];
        require(block.timestamp <= slot.endTime, "Slot expired");
        require(amount >= slot.minAmount && amount <= slot.maxAmount, "Invalid amount");
        if (amount >= kycThreshold) require(_kycVerified[msg.sender], "KYC required");

        _balances[msg.sender] -= amount;
        _balances[address(this)] += amount;
        
        _stakes[msg.sender].push(Stake({
            amount: amount,
            startTimestamp: block.timestamp,
            duration: slot.endTime - block.timestamp,
            rewardRate: slot.apr,
            claimed: false
        }));

        slotStakes[slotId][msg.sender] += amount;
        emit SlotStaked(msg.sender, slotId, amount);
    }

    // --------------------------
    // KYC System Implementation
    // --------------------------

    /**
     * @dev Verifies user for KYC compliance
     * @param user Address to verify
     */
    function verifyKYC(address user) external onlyOwner {
        _kycVerified[user] = true;
        emit KYCVerified(user);
    }

    /**
     * @dev Updates KYC threshold
     * @param newThreshold New KYC requirement threshold
     */
    function setKYCThreshold(uint256 newThreshold) external onlyOwner {
        kycThreshold = newThreshold;
    }

    // --------------------------
    // Internal Helpers
    // --------------------------

    /**
     * @dev Internal approval implementation
     * @param owner Allowance provider
     * @param spender Allowance spender
     * @param amount Allowance amount
     */
    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0) && spender != address(0), "Invalid addresses");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    modifier onlyVotingAdmin() {
        require(_msgSender() == owner() || _msgSender() == votingManager, "Admin only");
        _;
    }

    // --------------------------
    // Additional View Functions
    // --------------------------

    /**
     * @dev Returns active APR slots
     * @return Array of active APR slots
     */
    function getActiveAPRSlots() external view returns (APRSlot[] memory) {
        APRSlot[] memory active = new APRSlot[](aprSlots.length);
        uint256 count;
        
        for(uint256 i = 0; i < aprSlots.length; i++) {
            if(aprSlots[i].active && block.timestamp <= aprSlots[i].endTime) {
                active[count] = aprSlots[i];
                count++;
            }
        }
        
        APRSlot[] memory result = new APRSlot[](count);
        for(uint256 i = 0; i < count; i++) {
            result[i] = active[i];
        }
        return result;
    }

    /**
     * @dev Returns user's active stakes
     * @param user Address to check
     * @return Array of active stakes
     */
    function getActiveStakes(address user) external view returns (Stake[] memory) {
        Stake[] memory allStakes = _stakes[user];
        Stake[] memory active = new Stake[](allStakes.length);
        uint256 count;
        
        for(uint256 i = 0; i < allStakes.length; i++) {
            if(!allStakes[i].claimed) {
                active[count] = allStakes[i];
                count++;
            }
        }
        
        Stake[] memory result = new Stake[](count);
        for(uint256 i = 0; i < count; i++) {
            result[i] = active[i];
        }
        return result;
    }

    /**
     * @dev Checks KYC verification status
     * @param user Address to check
     * @return Boolean indicating verification status
     */
    function isKYCVerified(address user) external view returns (bool) {
        return _kycVerified[user];
    }
}
