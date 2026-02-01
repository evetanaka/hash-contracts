// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./HashToken.sol";
import "./HashStaking.sol";
import "./HashJackpot.sol";

/**
 * @title HashGame
 * @notice Main game contract for HASH - Predict the block hash
 * @dev Fully onchain, no backend required
 */
contract HashGame is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // ============ Enums ============

    enum GameMode { ONE_DIGIT, TWO_DIGIT, THREE_DIGIT }
    enum BetStatus { PENDING, WON, LOST, EXPIRED, RIDING }

    // ============ Structs ============

    struct Bet {
        address player;
        uint256 amount;
        GameMode mode;
        uint16 prediction;       // 0-15 for 1 digit, 0-255 for 2, 0-4095 for 3
        uint256 targetBlock;
        BetStatus status;
        bool isRide;
        uint256 payout;          // Calculated payout if won
    }

    // ============ Constants ============

    uint256 public constant BLOCKS_TO_WAIT = 10;     // Bet on block N+10 (safer)
    uint256 public constant MAX_BLOCK_AGE = 256;     // Blockhash available for 256 blocks
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MIN_BET = 1e18;          // Minimum 1 token
    
    // Revenue distribution (in basis points)
    uint256 public constant BURN_BPS = 4000;         // 40%
    uint256 public constant JACKPOT_BPS = 2000;      // 20%
    uint256 public constant STAKERS_BPS = 2000;      // 20% base
    uint256 public constant INFRA_BPS = 1000;        // 10%
    uint256 public constant REFERRAL_MAX_BPS = 1000; // Up to 10%
    
    // Payouts (multipliers)
    uint256 public constant PAYOUT_1_DIGIT = 10;
    uint256 public constant PAYOUT_2_DIGIT = 150;
    uint256 public constant PAYOUT_3_DIGIT = 2000;
    uint256 public constant RIDE_MULTIPLIER = 2;     // 2x boost on ride
    
    // Jackpot
    uint256 public constant JACKPOT_STREAK = 5;

    // ============ State ============

    HashToken public immutable hashToken;
    HashStaking public immutable staking;
    HashJackpot public immutable jackpot;
    
    address public treasury;
    
    mapping(uint256 => Bet) public bets;
    uint256 public nextBetId;
    
    // Streak tracking
    mapping(address => uint8) public currentStreak;
    mapping(address => GameMode) public streakMode;
    
    // Stats
    uint256 public totalVolume;
    uint256 public totalBurned;
    
    // Price feed (simplified - in production use Chainlink)
    uint256 public tokenPriceUsd = 1e7;  // Default $0.10 per token (scaled by 1e8)

    // ============ Events ============

    event BetPlaced(
        uint256 indexed betId,
        address indexed player,
        GameMode mode,
        uint16 prediction,
        uint256 amount,
        uint256 targetBlock
    );
    
    event BetResolved(
        uint256 indexed betId,
        address indexed player,
        bool won,
        uint16 result,
        uint256 payout
    );
    
    event RidePlaced(
        uint256 indexed newBetId,
        uint256 indexed originalBetId,
        uint256 amount
    );
    
    event RevenueDistributed(
        uint256 burned,
        uint256 toJackpot,
        uint256 toStakers,
        uint256 toTreasury,
        uint256 toReferrer
    );

    event TokenPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    // ============ Constructor ============

    constructor(
        address _hashToken,
        address _staking,
        address _jackpot,
        address _treasury
    ) Ownable(msg.sender) {
        require(_hashToken != address(0), "Invalid token");
        require(_staking != address(0), "Invalid staking");
        require(_jackpot != address(0), "Invalid jackpot");
        require(_treasury != address(0), "Invalid treasury");
        
        hashToken = HashToken(_hashToken);
        staking = HashStaking(_staking);
        jackpot = HashJackpot(_jackpot);
        treasury = _treasury;
    }

    // ============ External Functions ============

    /**
     * @notice Place a bet
     * @param mode Game mode (1, 2, or 3 digits)
     * @param prediction Your prediction (hex value)
     * @param amount Bet amount in tokens
     */
    function placeBet(
        GameMode mode,
        uint16 prediction,
        uint256 amount
    ) external nonReentrant whenNotPaused returns (uint256 betId) {
        require(amount >= MIN_BET, "Below minimum bet");
        
        // Validate prediction range
        _validatePrediction(mode, prediction);
        
        // Check tier limits
        (,, uint256 maxBetUsd,) = staking.getUserTierInfo(msg.sender);
        uint256 maxBetTokens = (maxBetUsd * 1e18) / tokenPriceUsd;
        require(amount <= maxBetTokens, "Exceeds max bet for tier");
        
        // Transfer tokens
        IERC20(address(hashToken)).safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate potential payout
        uint256 payout = _calculatePayout(msg.sender, mode, amount, false);
        
        // Create bet
        betId = nextBetId++;
        bets[betId] = Bet({
            player: msg.sender,
            amount: amount,
            mode: mode,
            prediction: prediction,
            targetBlock: block.number + BLOCKS_TO_WAIT,
            status: BetStatus.PENDING,
            isRide: false,
            payout: payout
        });
        
        totalVolume += amount;
        
        emit BetPlaced(betId, msg.sender, mode, prediction, amount, block.number + BLOCKS_TO_WAIT);
    }

    /**
     * @notice Resolve a bet (can be called by anyone)
     * @param betId ID of the bet to resolve
     */
    function resolveBet(uint256 betId) external nonReentrant {
        Bet storage bet = bets[betId];
        require(bet.status == BetStatus.PENDING, "Bet not pending");
        require(block.number > bet.targetBlock, "Target block not mined");
        
        // Check if expired
        if (block.number > bet.targetBlock + MAX_BLOCK_AGE) {
            bet.status = BetStatus.EXPIRED;
            // Refund on expiry minus small fee
            uint256 expiryFee = bet.amount / 100;  // 1% expiry fee
            uint256 refund = bet.amount - expiryFee;
            
            IERC20(address(hashToken)).safeTransfer(bet.player, refund);
            IERC20(address(hashToken)).safeTransfer(treasury, expiryFee);
            
            emit BetResolved(betId, bet.player, false, 0, refund);
            return;
        }
        
        bytes32 blockHash = blockhash(bet.targetBlock);
        require(blockHash != bytes32(0), "Block hash not available");
        
        uint16 result = _extractResult(bet.mode, blockHash);
        bool won = (result == bet.prediction);
        
        if (won) {
            bet.status = BetStatus.WON;
            _processWin(bet);
        } else {
            bet.status = BetStatus.LOST;
            _processLoss(bet);
        }
        
        emit BetResolved(betId, bet.player, won, result, won ? bet.payout : 0);
    }

    /**
     * @notice Ride winnings with 2x boost
     * @param originalBetId ID of the winning bet
     * @param newPrediction New prediction for the ride
     */
    function rideWinnings(
        uint256 originalBetId,
        uint16 newPrediction
    ) external nonReentrant whenNotPaused returns (uint256 newBetId) {
        Bet storage originalBet = bets[originalBetId];
        require(originalBet.player == msg.sender, "Not your bet");
        require(originalBet.status == BetStatus.WON, "Bet not won");
        
        _validatePrediction(originalBet.mode, newPrediction);
        
        uint256 rideAmount = originalBet.payout;
        
        // Mark original as riding (funds locked)
        originalBet.status = BetStatus.RIDING;
        
        // Calculate new payout with ride bonus
        uint256 newPayout = _calculatePayout(msg.sender, originalBet.mode, rideAmount, true);
        
        // Create ride bet
        newBetId = nextBetId++;
        bets[newBetId] = Bet({
            player: msg.sender,
            amount: rideAmount,
            mode: originalBet.mode,
            prediction: newPrediction,
            targetBlock: block.number + BLOCKS_TO_WAIT,
            status: BetStatus.PENDING,
            isRide: true,
            payout: newPayout
        });
        
        totalVolume += rideAmount;
        
        emit RidePlaced(newBetId, originalBetId, rideAmount);
    }

    /**
     * @notice Cash out winnings (alternative to ride)
     * @param betId ID of the winning bet
     */
    function cashOut(uint256 betId) external nonReentrant {
        Bet storage bet = bets[betId];
        require(bet.player == msg.sender, "Not your bet");
        require(bet.status == BetStatus.WON, "Bet not won");
        
        bet.status = BetStatus.EXPIRED; // Mark as claimed
        IERC20(address(hashToken)).safeTransfer(msg.sender, bet.payout);
    }

    // ============ View Functions ============

    /**
     * @notice Get bet details
     */
    function getBet(uint256 betId) external view returns (
        address player,
        uint256 amount,
        GameMode mode,
        uint16 prediction,
        uint256 targetBlock,
        BetStatus status,
        bool isRide,
        uint256 payout
    ) {
        Bet memory bet = bets[betId];
        return (
            bet.player,
            bet.amount,
            bet.mode,
            bet.prediction,
            bet.targetBlock,
            bet.status,
            bet.isRide,
            bet.payout
        );
    }

    /**
     * @notice Preview payout for a potential bet
     */
    function previewPayout(
        address player,
        GameMode mode,
        uint256 amount,
        bool isRide
    ) external view returns (uint256) {
        return _calculatePayout(player, mode, amount, isRide);
    }

    /**
     * @notice Get current streak for a player
     */
    function getStreak(address player) external view returns (uint8 streak, GameMode mode) {
        return (currentStreak[player], streakMode[player]);
    }

    /**
     * @notice Get game stats
     */
    function getStats() external view returns (
        uint256 volume,
        uint256 burned,
        uint256 jackpotPot,
        uint256 betsCount
    ) {
        return (totalVolume, totalBurned, jackpot.currentPot(), nextBetId);
    }

    // ============ Admin Functions ============

    function setTokenPrice(uint256 newPrice) external onlyOwner {
        require(newPrice > 0, "Invalid price");
        emit TokenPriceUpdated(tokenPriceUsd, newPrice);
        tokenPriceUsd = newPrice;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury");
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Internal Functions ============

    function _validatePrediction(GameMode mode, uint16 prediction) internal pure {
        if (mode == GameMode.ONE_DIGIT) {
            require(prediction <= 15, "Invalid prediction for 1 digit");
        } else if (mode == GameMode.TWO_DIGIT) {
            require(prediction <= 255, "Invalid prediction for 2 digits");
        } else {
            require(prediction <= 4095, "Invalid prediction for 3 digits");
        }
    }

    function _extractResult(GameMode mode, bytes32 blockHash) internal pure returns (uint16) {
        if (mode == GameMode.ONE_DIGIT) {
            // Last hex character (4 bits)
            return uint16(uint8(blockHash[31]) & 0x0F);
        } else if (mode == GameMode.TWO_DIGIT) {
            // Last byte (8 bits = 2 hex chars)
            return uint16(uint8(blockHash[31]));
        } else {
            // Last 12 bits (3 hex chars)
            uint16 lastByte = uint16(uint8(blockHash[31]));
            uint16 secondLastNibble = uint16(uint8(blockHash[30]) & 0x0F) << 8;
            return secondLastNibble | lastByte;
        }
    }

    function _calculatePayout(
        address player,
        GameMode mode,
        uint256 amount,
        bool isRide
    ) internal view returns (uint256) {
        uint256 baseMultiplier;
        
        if (mode == GameMode.ONE_DIGIT) {
            baseMultiplier = PAYOUT_1_DIGIT;
        } else if (mode == GameMode.TWO_DIGIT) {
            baseMultiplier = PAYOUT_2_DIGIT;
        } else {
            baseMultiplier = PAYOUT_3_DIGIT;
        }
        
        if (isRide) {
            baseMultiplier *= RIDE_MULTIPLIER;
        }
        
        uint256 payout = amount * baseMultiplier;
        
        // Apply tier boost
        (, uint16 boostBps,,) = staking.getUserTierInfo(player);
        if (boostBps > 0) {
            payout = payout + (payout * boostBps) / BPS_DENOMINATOR;
        }
        
        return payout;
    }

    function _processWin(Bet storage bet) internal {
        // Update streak
        if (streakMode[bet.player] != bet.mode) {
            currentStreak[bet.player] = 1;
            streakMode[bet.player] = bet.mode;
        } else {
            currentStreak[bet.player]++;
        }
        
        // Check for jackpot (5 consecutive wins)
        if (currentStreak[bet.player] >= JACKPOT_STREAK) {
            currentStreak[bet.player] = 0;  // Reset streak
            jackpot.awardStreakWinner(bet.player);
        }
        
        // Note: Payout not transferred here - player must call cashOut() or rideWinnings()
    }

    function _processLoss(Bet storage bet) internal {
        // Reset streak
        currentStreak[bet.player] = 0;
        
        // Distribute revenue
        uint256 revenue = bet.amount;
        
        // Calculate distributions
        uint256 burnAmount = (revenue * BURN_BPS) / BPS_DENOMINATOR;
        uint256 jackpotAmount = (revenue * JACKPOT_BPS) / BPS_DENOMINATOR;
        uint256 infraAmount = (revenue * INFRA_BPS) / BPS_DENOMINATOR;
        
        // Handle referral
        address referrer = staking.referrers(bet.player);
        uint256 referralAmount = 0;
        uint256 extraToStakers = 0;
        
        if (referrer != address(0)) {
            (,,, uint16 referralFeeBps) = staking.getUserTierInfo(referrer);
            referralAmount = (revenue * referralFeeBps) / BPS_DENOMINATOR;
            extraToStakers = (revenue * REFERRAL_MAX_BPS) / BPS_DENOMINATOR - referralAmount;
        } else {
            extraToStakers = (revenue * REFERRAL_MAX_BPS) / BPS_DENOMINATOR;
        }
        
        uint256 stakersAmount = (revenue * STAKERS_BPS) / BPS_DENOMINATOR + extraToStakers;
        
        // Execute distributions
        
        // Burn
        hashToken.burnFromGame(address(this), burnAmount);
        totalBurned += burnAmount;
        
        // Jackpot - send to jackpot contract
        IERC20(address(hashToken)).approve(address(jackpot), jackpotAmount);
        jackpot.feed(jackpotAmount);
        
        // Infrastructure
        IERC20(address(hashToken)).safeTransfer(treasury, infraAmount);
        
        // Stakers
        IERC20(address(hashToken)).approve(address(staking), stakersAmount);
        staking.distributeRewards(stakersAmount);
        
        // Referral
        if (referralAmount > 0) {
            IERC20(address(hashToken)).safeTransfer(referrer, referralAmount);
        }
        
        emit RevenueDistributed(burnAmount, jackpotAmount, stakersAmount, infraAmount, referralAmount);
    }
}
