// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IHashJackpot {
    function registerStaker(address staker) external;
    function removeStaker(address staker) external;
}

/**
 * @title HashStaking
 * @notice Stake $HASH tokens for tier benefits and revenue share
 * @dev 12-month lock period with emergency exit, 5 tiers with increasing benefits
 */
contract HashStaking is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // ============ Structs ============

    struct Stake {
        uint256 amount;
        uint256 lockStart;
        uint256 lockEnd;
        uint256 rewardDebt;      // For reward calculation
        uint256 totalClaimed;
    }

    struct Tier {
        uint256 minStake;        // Minimum tokens to reach this tier
        uint16 boostBps;         // Payout boost in basis points (500 = 5%)
        uint256 maxBetUsd;       // Maximum bet in USD (scaled by 1e8)
        uint16 referralFeeBps;   // Referral fee in basis points
    }

    // ============ Constants ============

    uint256 public constant LOCK_DURATION = 365 days;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant EMERGENCY_PENALTY_BPS = 5000;  // 50% penalty for early exit
    uint256 public constant MAX_STAKE_PER_USER = 5_000_000 * 1e18;  // 5M max per user

    // ============ State ============

    IERC20 public immutable hashToken;
    IHashJackpot public jackpot;
    
    mapping(address => Stake) public stakes;
    mapping(address => address) public referrers;  // user => referrer
    
    Tier[5] public tiers;
    
    uint256 public totalStaked;
    uint256 public rewardPool;           // Accumulated rewards for distribution
    uint256 public accRewardPerShare;    // Accumulated rewards per share (scaled by 1e12)
    
    // ============ Events ============

    event Staked(address indexed user, uint256 amount, uint256 lockEnd);
    event StakeAdded(address indexed user, uint256 amount, uint256 newLockEnd);
    event Unstaked(address indexed user, uint256 amount);
    event EmergencyUnstaked(address indexed user, uint256 amount, uint256 penalty);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardsDistributed(uint256 amount);
    event ReferrerSet(address indexed user, address indexed referrer);
    event JackpotSet(address indexed jackpot);

    // ============ Constructor ============

    constructor(address _hashToken) Ownable(msg.sender) {
        require(_hashToken != address(0), "Invalid token address");
        hashToken = IERC20(_hashToken);
        
        // Initialize tiers
        // Tier 0: Base (no stake required)
        tiers[0] = Tier({
            minStake: 0,
            boostBps: 0,
            maxBetUsd: 10 * 1e8,         // $10
            referralFeeBps: 300          // 3%
        });
        
        // Tier 1: Bronze
        tiers[1] = Tier({
            minStake: 1_000 * 1e18,
            boostBps: 500,               // 5%
            maxBetUsd: 100 * 1e8,        // $100
            referralFeeBps: 500          // 5%
        });
        
        // Tier 2: Silver
        tiers[2] = Tier({
            minStake: 10_000 * 1e18,
            boostBps: 1000,              // 10%
            maxBetUsd: 1_000 * 1e8,      // $1,000
            referralFeeBps: 700          // 7%
        });
        
        // Tier 3: Gold
        tiers[3] = Tier({
            minStake: 100_000 * 1e18,
            boostBps: 1500,              // 15%
            maxBetUsd: 5_000 * 1e8,      // $5,000
            referralFeeBps: 800          // 8%
        });
        
        // Tier 4: Diamond
        tiers[4] = Tier({
            minStake: 1_000_000 * 1e18,
            boostBps: 2000,              // 20%
            maxBetUsd: 10_000 * 1e8,     // $10,000
            referralFeeBps: 1000         // 10%
        });
    }

    // ============ External Functions ============

    /**
     * @notice Stake tokens (12-month lock)
     * @param amount Amount of tokens to stake
     * @param referrer Optional referrer address
     */
    function stake(uint256 amount, address referrer) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be > 0");
        require(stakes[msg.sender].amount == 0, "Already staking, use addToStake");
        require(amount <= MAX_STAKE_PER_USER, "Exceeds max stake per user");
        
        // Set referrer if provided and not already set
        if (referrer != address(0) && referrers[msg.sender] == address(0) && referrer != msg.sender) {
            referrers[msg.sender] = referrer;
            emit ReferrerSet(msg.sender, referrer);
        }
        
        hashToken.safeTransferFrom(msg.sender, address(this), amount);
        
        stakes[msg.sender] = Stake({
            amount: amount,
            lockStart: block.timestamp,
            lockEnd: block.timestamp + LOCK_DURATION,
            rewardDebt: (amount * accRewardPerShare) / 1e12,
            totalClaimed: 0
        });
        
        totalStaked += amount;
        
        // Register for jackpot lottery
        if (address(jackpot) != address(0)) {
            jackpot.registerStaker(msg.sender);
        }
        
        emit Staked(msg.sender, amount, block.timestamp + LOCK_DURATION);
    }

    /**
     * @notice Add more tokens to existing stake (resets lock period)
     * @param amount Amount to add
     */
    function addToStake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be > 0");
        require(stakes[msg.sender].amount > 0, "No existing stake");
        
        Stake storage s = stakes[msg.sender];
        require(s.amount + amount <= MAX_STAKE_PER_USER, "Exceeds max stake per user");
        
        // Claim pending rewards first
        _claimRewards(msg.sender);
        
        hashToken.safeTransferFrom(msg.sender, address(this), amount);
        
        s.amount += amount;
        s.lockStart = block.timestamp;
        s.lockEnd = block.timestamp + LOCK_DURATION;
        s.rewardDebt = (s.amount * accRewardPerShare) / 1e12;
        
        totalStaked += amount;
        
        emit StakeAdded(msg.sender, amount, s.lockEnd);
    }

    /**
     * @notice Unstake tokens after lock period
     */
    function unstake() external nonReentrant {
        Stake storage s = stakes[msg.sender];
        require(s.amount > 0, "No stake");
        require(block.timestamp >= s.lockEnd, "Still locked");
        
        // Claim pending rewards
        _claimRewards(msg.sender);
        
        uint256 amount = s.amount;
        totalStaked -= amount;
        
        // Remove from jackpot lottery
        if (address(jackpot) != address(0)) {
            jackpot.removeStaker(msg.sender);
        }
        
        delete stakes[msg.sender];
        
        hashToken.safeTransfer(msg.sender, amount);
        
        emit Unstaked(msg.sender, amount);
    }

    /**
     * @notice Emergency unstake with 50% penalty (before lock expires)
     */
    function emergencyUnstake() external nonReentrant {
        Stake storage s = stakes[msg.sender];
        require(s.amount > 0, "No stake");
        require(block.timestamp < s.lockEnd, "Lock expired, use normal unstake");
        
        // Claim pending rewards first
        _claimRewards(msg.sender);
        
        uint256 amount = s.amount;
        uint256 penalty = (amount * EMERGENCY_PENALTY_BPS) / BPS_DENOMINATOR;
        uint256 refund = amount - penalty;
        
        totalStaked -= amount;
        
        // Remove from jackpot lottery
        if (address(jackpot) != address(0)) {
            jackpot.removeStaker(msg.sender);
        }
        
        delete stakes[msg.sender];
        
        // Penalty goes to other stakers
        if (totalStaked > 0) {
            accRewardPerShare += (penalty * 1e12) / totalStaked;
            rewardPool += penalty;
        } else {
            // No other stakers, burn the penalty
            // Note: Would need burn function, for now send to contract
        }
        
        hashToken.safeTransfer(msg.sender, refund);
        
        emit EmergencyUnstaked(msg.sender, refund, penalty);
    }

    /**
     * @notice Claim accumulated rewards
     */
    function claimRewards() external nonReentrant {
        _claimRewards(msg.sender);
    }

    /**
     * @notice Distribute rewards to stakers (called by game contract)
     * @param amount Amount of tokens to distribute
     */
    function distributeRewards(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        
        if (totalStaked == 0) {
            // No stakers, send to owner as fallback
            hashToken.safeTransferFrom(msg.sender, owner(), amount);
            return;
        }
        
        hashToken.safeTransferFrom(msg.sender, address(this), amount);
        
        accRewardPerShare += (amount * 1e12) / totalStaked;
        rewardPool += amount;
        
        emit RewardsDistributed(amount);
    }

    // ============ View Functions ============

    /**
     * @notice Get user's current tier
     * @param user Address to check
     * @return Tier index (0-4)
     */
    function getTier(address user) public view returns (uint8) {
        uint256 staked = stakes[user].amount;
        
        for (uint8 i = 4; i > 0; i--) {
            if (staked >= tiers[i].minStake) {
                return i;
            }
        }
        return 0;
    }

    /**
     * @notice Get tier info for a user
     * @param user Address to check
     * @return tier Tier index
     * @return boostBps Payout boost in basis points
     * @return maxBetUsd Maximum bet in USD (scaled by 1e8)
     * @return referralFeeBps Referral fee in basis points
     */
    function getUserTierInfo(address user) external view returns (
        uint8 tier,
        uint16 boostBps,
        uint256 maxBetUsd,
        uint16 referralFeeBps
    ) {
        tier = getTier(user);
        Tier memory t = tiers[tier];
        return (tier, t.boostBps, t.maxBetUsd, t.referralFeeBps);
    }

    /**
     * @notice Get pending rewards for a user
     * @param user Address to check
     * @return Pending reward amount
     */
    function pendingRewards(address user) external view returns (uint256) {
        Stake memory s = stakes[user];
        if (s.amount == 0) return 0;
        
        uint256 pending = (s.amount * accRewardPerShare) / 1e12 - s.rewardDebt;
        return pending;
    }

    /**
     * @notice Get stake info for a user
     * @param user Address to check
     * @return amount Staked amount
     * @return lockEnd Lock end timestamp
     * @return isLocked Whether still locked
     * @return daysRemaining Days until unlock
     */
    function getStakeInfo(address user) external view returns (
        uint256 amount,
        uint256 lockEnd,
        bool isLocked,
        uint256 daysRemaining
    ) {
        Stake memory s = stakes[user];
        amount = s.amount;
        lockEnd = s.lockEnd;
        isLocked = block.timestamp < s.lockEnd;
        daysRemaining = isLocked ? (s.lockEnd - block.timestamp) / 1 days : 0;
    }

    /**
     * @notice Get global staking stats
     */
    function getGlobalStats() external view returns (
        uint256 _totalStaked,
        uint256 _rewardPool,
        uint256 _accRewardPerShare
    ) {
        return (totalStaked, rewardPool, accRewardPerShare);
    }

    // ============ Admin Functions ============

    /**
     * @notice Set jackpot contract address
     * @param _jackpot Jackpot contract address
     */
    function setJackpot(address _jackpot) external onlyOwner {
        require(_jackpot != address(0), "Invalid jackpot");
        jackpot = IHashJackpot(_jackpot);
        emit JackpotSet(_jackpot);
    }

    /**
     * @notice Update tier configuration
     * @param tierIndex Tier to update (0-4)
     * @param minStake Minimum stake for tier
     * @param boostBps Boost in basis points
     * @param maxBetUsd Max bet in USD (scaled by 1e8)
     * @param referralFeeBps Referral fee in basis points
     */
    function setTier(
        uint8 tierIndex,
        uint256 minStake,
        uint16 boostBps,
        uint256 maxBetUsd,
        uint16 referralFeeBps
    ) external onlyOwner {
        require(tierIndex < 5, "Invalid tier");
        require(boostBps <= 5000, "Boost too high");  // Max 50%
        require(referralFeeBps <= 1000, "Referral fee too high");  // Max 10%
        
        tiers[tierIndex] = Tier({
            minStake: minStake,
            boostBps: boostBps,
            maxBetUsd: maxBetUsd,
            referralFeeBps: referralFeeBps
        });
    }

    /**
     * @notice Admin function to reset referrer (for disputes)
     * @param user User to reset
     * @param newReferrer New referrer (can be zero)
     */
    function adminSetReferrer(address user, address newReferrer) external onlyOwner {
        require(user != newReferrer, "Cannot self-refer");
        referrers[user] = newReferrer;
        emit ReferrerSet(user, newReferrer);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Internal Functions ============

    function _claimRewards(address user) internal {
        Stake storage s = stakes[user];
        if (s.amount == 0) return;
        
        uint256 pending = (s.amount * accRewardPerShare) / 1e12 - s.rewardDebt;
        
        if (pending > 0) {
            s.rewardDebt = (s.amount * accRewardPerShare) / 1e12;
            s.totalClaimed += pending;
            hashToken.safeTransfer(user, pending);
            emit RewardsClaimed(user, pending);
        }
    }
}
