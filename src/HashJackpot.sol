// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./HashStaking.sol";

/**
 * @title HashJackpot
 * @notice Isolated jackpot pool with automatic must-drop lottery
 * @dev Feeds from game losses, drops monthly via weighted staker lottery
 */
contract HashJackpot is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ============ State ============

    IERC20 public immutable hashToken;
    HashStaking public immutable staking;
    address public gameContract;

    uint256 public currentPot;
    uint256 public lastDropTimestamp;
    
    // Must-drop config
    uint256 public dropInterval = 30 days;           // Monthly drop if no streak winner
    uint256 public minPotForDrop = 100_000 * 1e18;   // Min 100k tokens to drop
    
    // Stats
    uint256 public totalDropped;
    uint256 public totalStreakWins;
    uint256 public dropCount;

    // Registered stakers for lottery (updated by staking contract)
    address[] public registeredStakers;
    mapping(address => uint256) public stakerIndex;
    mapping(address => bool) public isRegistered;

    // ============ Events ============

    event JackpotFed(uint256 amount, uint256 newTotal);
    event StreakJackpotWon(address indexed winner, uint256 amount);
    event MustDropTriggered(address indexed winner, uint256 amount, uint256 winnerStake, uint256 totalStaked);
    event StakerRegistered(address indexed staker);
    event StakerRemoved(address indexed staker);
    event ConfigUpdated(uint256 dropInterval, uint256 minPotForDrop);

    // ============ Modifiers ============

    modifier onlyGame() {
        require(msg.sender == gameContract, "Only game contract");
        _;
    }

    modifier onlyStaking() {
        require(msg.sender == address(staking), "Only staking contract");
        _;
    }

    // ============ Constructor ============

    constructor(
        address _hashToken,
        address _staking
    ) Ownable(msg.sender) {
        require(_hashToken != address(0), "Invalid token");
        require(_staking != address(0), "Invalid staking");
        
        hashToken = IERC20(_hashToken);
        staking = HashStaking(_staking);
        lastDropTimestamp = block.timestamp;
    }

    // ============ External Functions ============

    /**
     * @notice Feed tokens into the jackpot (called by game on losses)
     * @param amount Amount to add to pot
     */
    function feed(uint256 amount) external onlyGame {
        require(amount > 0, "Amount must be > 0");
        
        hashToken.safeTransferFrom(msg.sender, address(this), amount);
        currentPot += amount;
        
        emit JackpotFed(amount, currentPot);
    }

    /**
     * @notice Award jackpot to streak winner (5 consecutive wins)
     * @param winner Address of the winner
     */
    function awardStreakWinner(address winner) external onlyGame nonReentrant {
        require(winner != address(0), "Invalid winner");
        require(currentPot > 0, "Pot is empty");
        
        // Streak winner gets 100% of the pot
        uint256 prize = currentPot;
        currentPot = 0;
        
        // Reset must-drop timer (pot was claimed)
        lastDropTimestamp = block.timestamp;
        
        totalStreakWins++;
        totalDropped += prize;
        
        hashToken.safeTransfer(winner, prize);
        
        emit StreakJackpotWon(winner, prize);
    }

    /**
     * @notice Trigger must-drop lottery (callable by anyone after interval)
     * @dev Uses weighted random selection based on stake size
     */
    function triggerMustDrop() external nonReentrant {
        require(block.timestamp >= lastDropTimestamp + dropInterval, "Too early");
        require(currentPot >= minPotForDrop, "Pot below minimum");
        require(registeredStakers.length > 0, "No stakers registered");
        
        // Calculate total staked among registered stakers
        uint256 totalWeight = 0;
        uint256[] memory weights = new uint256[](registeredStakers.length);
        
        for (uint256 i = 0; i < registeredStakers.length; i++) {
            (uint256 staked,,,) = staking.getStakeInfo(registeredStakers[i]);
            weights[i] = staked;
            totalWeight += staked;
        }
        
        require(totalWeight > 0, "No active stakes");
        
        // Generate pseudo-random number
        // Note: For production, use Chainlink VRF
        uint256 random = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            currentPot,
            totalWeight,
            registeredStakers.length
        )));
        
        // Weighted selection
        uint256 target = random % totalWeight;
        uint256 cumulative = 0;
        address winner;
        uint256 winnerStake;
        
        for (uint256 i = 0; i < registeredStakers.length; i++) {
            cumulative += weights[i];
            if (target < cumulative) {
                winner = registeredStakers[i];
                winnerStake = weights[i];
                break;
            }
        }
        
        require(winner != address(0), "No winner selected");
        
        // Award 100% of pot on must-drop
        uint256 prize = currentPot;
        currentPot = 0;
        
        lastDropTimestamp = block.timestamp;
        dropCount++;
        totalDropped += prize;
        
        hashToken.safeTransfer(winner, prize);
        
        emit MustDropTriggered(winner, prize, winnerStake, totalWeight);
    }

    /**
     * @notice Check if must-drop can be triggered
     */
    function canTriggerMustDrop() external view returns (bool ready, uint256 timeRemaining, uint256 potAmount) {
        potAmount = currentPot;
        
        if (block.timestamp >= lastDropTimestamp + dropInterval) {
            timeRemaining = 0;
            ready = currentPot >= minPotForDrop && registeredStakers.length > 0;
        } else {
            timeRemaining = (lastDropTimestamp + dropInterval) - block.timestamp;
            ready = false;
        }
    }

    /**
     * @notice Get lottery odds for a staker
     * @param staker Address to check
     * @return odds Percentage chance (scaled by 1e4, so 10000 = 100%)
     */
    function getLotteryOdds(address staker) external view returns (uint256 odds) {
        if (!isRegistered[staker]) return 0;
        
        (uint256 stakerAmount,,,) = staking.getStakeInfo(staker);
        if (stakerAmount == 0) return 0;
        
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < registeredStakers.length; i++) {
            (uint256 staked,,,) = staking.getStakeInfo(registeredStakers[i]);
            totalWeight += staked;
        }
        
        if (totalWeight == 0) return 0;
        
        odds = (stakerAmount * 10000) / totalWeight;
    }

    // ============ Staker Registry (called by HashStaking) ============

    /**
     * @notice Register a staker for lottery eligibility
     * @param staker Address to register
     */
    function registerStaker(address staker) external onlyStaking {
        if (!isRegistered[staker]) {
            stakerIndex[staker] = registeredStakers.length;
            registeredStakers.push(staker);
            isRegistered[staker] = true;
            emit StakerRegistered(staker);
        }
    }

    /**
     * @notice Remove a staker from lottery (on unstake)
     * @param staker Address to remove
     */
    function removeStaker(address staker) external onlyStaking {
        if (isRegistered[staker]) {
            uint256 index = stakerIndex[staker];
            uint256 lastIndex = registeredStakers.length - 1;
            
            if (index != lastIndex) {
                address lastStaker = registeredStakers[lastIndex];
                registeredStakers[index] = lastStaker;
                stakerIndex[lastStaker] = index;
            }
            
            registeredStakers.pop();
            delete stakerIndex[staker];
            isRegistered[staker] = false;
            
            emit StakerRemoved(staker);
        }
    }

    /**
     * @notice Get number of registered stakers
     */
    function getRegisteredStakersCount() external view returns (uint256) {
        return registeredStakers.length;
    }

    // ============ Admin Functions ============

    function setGameContract(address _game) external onlyOwner {
        require(_game != address(0), "Invalid game");
        gameContract = _game;
    }

    function setDropConfig(
        uint256 _dropInterval,
        uint256 _minPotForDrop
    ) external onlyOwner {
        require(_dropInterval >= 7 days, "Interval too short");
        
        dropInterval = _dropInterval;
        minPotForDrop = _minPotForDrop;
        
        emit ConfigUpdated(_dropInterval, _minPotForDrop);
    }

    // ============ View Functions ============

    /**
     * @notice Get jackpot stats
     */
    function getStats() external view returns (
        uint256 pot,
        uint256 nextDropTime,
        uint256 totalPaidOut,
        uint256 streakWinsCount,
        uint256 mustDropCount,
        uint256 stakersCount
    ) {
        pot = currentPot;
        nextDropTime = lastDropTimestamp + dropInterval;
        totalPaidOut = totalDropped;
        streakWinsCount = totalStreakWins;
        mustDropCount = dropCount;
        stakersCount = registeredStakers.length;
    }
}
