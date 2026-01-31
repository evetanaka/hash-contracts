// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title HashToken
 * @notice ERC-20 token for the HASH game ecosystem
 * @dev Fixed supply of 100M tokens, burnable by authorized contracts
 */
contract HashToken is ERC20, ERC20Burnable, AccessControl {
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    
    uint256 public constant MAX_SUPPLY = 100_000_000 * 10**18; // 100M tokens
    
    // Track total burned for transparency
    uint256 public totalBurned;

    event TokensBurned(address indexed from, uint256 amount, uint256 totalBurned);

    constructor(address initialHolder) ERC20("Hash Game", "HASH") {
        require(initialHolder != address(0), "Invalid initial holder");
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _mint(initialHolder, MAX_SUPPLY);
    }

    /**
     * @notice Burn tokens from an account (requires BURNER_ROLE)
     * @param account Address to burn from
     * @param amount Amount to burn
     */
    function burnFromGame(address account, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(account, amount);
        totalBurned += amount;
        emit TokensBurned(account, amount, totalBurned);
    }

    /**
     * @notice Get circulating supply (total supply minus burned)
     */
    function circulatingSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalBurned;
    }
}
