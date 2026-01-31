// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title HashStaking
 * @notice Stake $HASH tokens for tier benefits and revenue share
 * @dev 12-month lock period, 5 tiers with increasing benefits
 */
contract HashStaking is ReentrancyGuard, Ownable {
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

    // ============ State ============

    IERC20 public immutable hashToken;
    
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
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardsDistributed(uint256 amount);
    event ReferrerSet(address indexed user, address indexed referrer);

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
    function stake(uint256 amount, address referrer) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(stakes[msg.sender].amount == 0, "Already staking, use addToStake");
        
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
        
        emit Staked(msg.sender, amount, block.timestamp + LOCK_DURATION);
    }

    /**
     * @notice Add more tokens to existing stake (resets lock period)
     * @param amount Amount to add
     */
    function addToStake(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(stakes[msg.sender].amount > 0, "No existing stake");
        
        // Claim pending rewards first
        _claimRewards(msg.sender);
        
        hashToken.safeTransferFrom(msg.sender, address(this), amount);
        
        Stake storage s = stakes[msg.sender];
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
        
        delete stakes[msg.sender];
        
        hashToken.safeTransfer(msg.sender, amount);
        
        emit Unstaked(msg.sender, amount);
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
        require(totalStaked > 0, "No stakers");
        
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
