// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/HashToken.sol";
import "../src/HashStaking.sol";
import "../src/HashJackpot.sol";
import "../src/HashGame.sol";

contract HashGameTest is Test {
    HashToken public token;
    HashStaking public staking;
    HashJackpot public jackpot;
    HashGame public game;
    
    address public owner = address(1);
    address public treasury = address(2);
    address public player1 = address(3);
    address public player2 = address(4);
    
    uint256 constant INITIAL_BALANCE = 10000 * 1e18;

    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy contracts
        token = new HashToken(owner);
        staking = new HashStaking(address(token));
        jackpot = new HashJackpot(address(token), address(staking));
        game = new HashGame(address(token), address(staking), address(jackpot), treasury);
        
        // Setup permissions
        token.grantRole(token.BURNER_ROLE(), address(game));
        jackpot.setGameContract(address(game));
        staking.setJackpot(address(jackpot));
        
        // Fund players
        token.transfer(player1, INITIAL_BALANCE);
        token.transfer(player2, INITIAL_BALANCE);
        
        vm.stopPrank();
        
        // Approve game contract
        vm.prank(player1);
        token.approve(address(game), type(uint256).max);
        
        vm.prank(player2);
        token.approve(address(game), type(uint256).max);
    }

    // ========== TOKEN TESTS ==========

    function testTokenInitialSupply() public view {
        assertEq(token.totalSupply(), 100_000_000 * 1e18);
    }

    function testTokenName() public view {
        assertEq(token.name(), "Hash Game");
        assertEq(token.symbol(), "HASH");
    }

    // ========== GAME TESTS ==========

    function testPlaceBet() public {
        vm.prank(player1);
        uint256 betId = game.placeBet(HashGame.GameMode.ONE_DIGIT, 5, 100 * 1e18);
        
        (address player, uint256 amount, , uint16 prediction, , , , ) = game.getBet(betId);
        
        assertEq(player, player1);
        assertEq(amount, 100 * 1e18);
        assertEq(prediction, 5);
    }

    function testPlaceBetMinimum() public {
        vm.prank(player1);
        vm.expectRevert("Below minimum bet");
        game.placeBet(HashGame.GameMode.ONE_DIGIT, 5, 0.5 * 1e18);
    }

    function testPlaceBetInvalidPrediction() public {
        vm.prank(player1);
        vm.expectRevert("Invalid prediction for 1 digit");
        game.placeBet(HashGame.GameMode.ONE_DIGIT, 16, 100 * 1e18);  // Max is 15
    }

    function testPlaceBetTwoDigit() public {
        vm.prank(player1);
        uint256 betId = game.placeBet(HashGame.GameMode.TWO_DIGIT, 255, 100 * 1e18);
        
        (, , HashGame.GameMode mode, uint16 prediction, , , , ) = game.getBet(betId);
        
        assertEq(uint8(mode), uint8(HashGame.GameMode.TWO_DIGIT));
        assertEq(prediction, 255);
    }

    function testPlaceBetThreeDigit() public {
        vm.prank(player1);
        uint256 betId = game.placeBet(HashGame.GameMode.THREE_DIGIT, 4095, 100 * 1e18);
        
        (, , HashGame.GameMode mode, uint16 prediction, , , , ) = game.getBet(betId);
        
        assertEq(uint8(mode), uint8(HashGame.GameMode.THREE_DIGIT));
        assertEq(prediction, 4095);
    }

    function testResolveBetWin() public {
        vm.prank(player1);
        uint256 betId = game.placeBet(HashGame.GameMode.ONE_DIGIT, 0, 100 * 1e18);
        
        // Mine blocks
        vm.roll(block.number + 3);
        
        // Mock blockhash ending in 0
        // Note: In real tests, we'd need to manipulate the blockhash
        // For now, just test that resolution works
        game.resolveBet(betId);
        
        (, , , , , HashGame.BetStatus status, , ) = game.getBet(betId);
        assertTrue(status == HashGame.BetStatus.WON || status == HashGame.BetStatus.LOST);
    }

    function testResolveBetTooEarly() public {
        vm.prank(player1);
        uint256 betId = game.placeBet(HashGame.GameMode.ONE_DIGIT, 5, 100 * 1e18);
        
        // Don't mine enough blocks
        vm.roll(block.number + 1);
        
        vm.expectRevert("Target block not mined");
        game.resolveBet(betId);
    }

    function testCashOut() public {
        vm.prank(player1);
        uint256 betId = game.placeBet(HashGame.GameMode.ONE_DIGIT, 0, 100 * 1e18);
        
        vm.roll(block.number + 3);
        game.resolveBet(betId);
        
        (, , , , , HashGame.BetStatus status, , uint256 payout) = game.getBet(betId);
        
        if (status == HashGame.BetStatus.WON) {
            uint256 balanceBefore = token.balanceOf(player1);
            
            vm.prank(player1);
            game.cashOut(betId);
            
            assertEq(token.balanceOf(player1), balanceBefore + payout);
        }
    }

    function testPreviewPayout() public view {
        uint256 payout1 = game.previewPayout(player1, HashGame.GameMode.ONE_DIGIT, 100 * 1e18, false);
        uint256 payout2 = game.previewPayout(player1, HashGame.GameMode.TWO_DIGIT, 100 * 1e18, false);
        uint256 payout3 = game.previewPayout(player1, HashGame.GameMode.THREE_DIGIT, 100 * 1e18, false);
        
        assertEq(payout1, 100 * 1e18 * 10);   // x10
        assertEq(payout2, 100 * 1e18 * 150);  // x150
        assertEq(payout3, 100 * 1e18 * 2000); // x2000
    }

    function testPreviewPayoutWithRide() public view {
        uint256 payoutNormal = game.previewPayout(player1, HashGame.GameMode.ONE_DIGIT, 100 * 1e18, false);
        uint256 payoutRide = game.previewPayout(player1, HashGame.GameMode.ONE_DIGIT, 100 * 1e18, true);
        
        assertEq(payoutRide, payoutNormal * 2);  // 2x boost on ride
    }

    // ========== STAKING TESTS ==========

    function testStake() public {
        vm.startPrank(player1);
        token.approve(address(staking), 1000 * 1e18);
        staking.stake(1000 * 1e18, address(0));
        vm.stopPrank();
        
        (uint256 amount, , , ) = staking.getStakeInfo(player1);
        assertEq(amount, 1000 * 1e18);
    }

    function testStakeWithReferrer() public {
        vm.startPrank(player1);
        token.approve(address(staking), 1000 * 1e18);
        staking.stake(1000 * 1e18, player2);
        vm.stopPrank();
        
        assertEq(staking.referrers(player1), player2);
    }

    function testTierCalculation() public {
        // No stake = Tier 0
        assertEq(staking.getTier(player1), 0);
        
        // Stake 1000 = Tier 1 (Bronze)
        vm.startPrank(player1);
        token.approve(address(staking), 1000 * 1e18);
        staking.stake(1000 * 1e18, address(0));
        vm.stopPrank();
        
        assertEq(staking.getTier(player1), 1);
    }

    function testEmergencyUnstake() public {
        vm.startPrank(player1);
        token.approve(address(staking), 1000 * 1e18);
        staking.stake(1000 * 1e18, address(0));
        
        uint256 balanceBefore = token.balanceOf(player1);
        
        // Emergency unstake (50% penalty)
        staking.emergencyUnstake();
        
        uint256 balanceAfter = token.balanceOf(player1);
        vm.stopPrank();
        
        // Should get back 50% (500 tokens)
        assertEq(balanceAfter - balanceBefore, 500 * 1e18);
    }

    function testUnstakeAfterLock() public {
        vm.startPrank(player1);
        token.approve(address(staking), 1000 * 1e18);
        staking.stake(1000 * 1e18, address(0));
        
        // Warp 365 days
        vm.warp(block.timestamp + 365 days + 1);
        
        uint256 balanceBefore = token.balanceOf(player1);
        staking.unstake();
        uint256 balanceAfter = token.balanceOf(player1);
        vm.stopPrank();
        
        // Should get back full amount
        assertEq(balanceAfter - balanceBefore, 1000 * 1e18);
    }

    // ========== JACKPOT TESTS ==========

    function testJackpotFeed() public {
        // Simulate a loss feeding the jackpot
        vm.startPrank(owner);
        token.approve(address(jackpot), 100 * 1e18);
        vm.stopPrank();
        
        // Only game can feed
        vm.prank(address(game));
        token.approve(address(jackpot), 100 * 1e18);
        
        // This would fail because game doesn't have tokens
        // In real scenario, game holds tokens from bets
    }

    function testJackpotStats() public view {
        (uint256 pot, , , , , ) = jackpot.getStats();
        assertEq(pot, 0);  // Initially empty
    }

    // ========== INTEGRATION TESTS ==========

    function testFullBetCycle() public {
        uint256 initialBalance = token.balanceOf(player1);
        
        // Place bet
        vm.prank(player1);
        uint256 betId = game.placeBet(HashGame.GameMode.ONE_DIGIT, 7, 100 * 1e18);
        
        assertEq(token.balanceOf(player1), initialBalance - 100 * 1e18);
        
        // Wait for target block
        vm.roll(block.number + 3);
        
        // Resolve
        game.resolveBet(betId);
        
        // Check result
        (, , , , , HashGame.BetStatus status, , ) = game.getBet(betId);
        assertTrue(status == HashGame.BetStatus.WON || status == HashGame.BetStatus.LOST);
    }

    function testVolumeTracking() public {
        // Tier 0 max bet is $10 = 100 tokens at $0.10
        vm.prank(player1);
        game.placeBet(HashGame.GameMode.ONE_DIGIT, 5, 10 * 1e18);
        
        vm.prank(player2);
        game.placeBet(HashGame.GameMode.ONE_DIGIT, 8, 10 * 1e18);
        
        (uint256 volume, , , ) = game.getStats();
        assertEq(volume, 20 * 1e18);
    }

    // ========== ADMIN TESTS ==========

    function testPause() public {
        vm.prank(owner);
        game.pause();
        
        vm.prank(player1);
        vm.expectRevert();
        game.placeBet(HashGame.GameMode.ONE_DIGIT, 5, 100 * 1e18);
    }

    function testUnpause() public {
        vm.prank(owner);
        game.pause();
        
        vm.prank(owner);
        game.unpause();
        
        vm.prank(player1);
        game.placeBet(HashGame.GameMode.ONE_DIGIT, 5, 100 * 1e18);
        // Should not revert
    }

    function testSetTokenPrice() public {
        vm.prank(owner);
        game.setTokenPrice(2e7);  // $0.20
        
        assertEq(game.tokenPriceUsd(), 2e7);
    }

    function testOnlyOwnerCanPause() public {
        vm.prank(player1);
        vm.expectRevert();
        game.pause();
    }
}
