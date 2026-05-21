// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GovernanceToken
 * @notice ERC-20 governance token distributed via liquidity mining.
 *         Not upgradeable by design — token contract should be immutable.
 * @dev Owner (LiquidityMining contract) can mint up to a fixed cap.
 */
contract GovernanceToken is ERC20, ERC20Burnable, Ownable {
    uint256 public constant MAX_SUPPLY = 100_000_000 * 1e18; // 100M tokens

    constructor(address initialOwner)
        ERC20("DeFi Protocol Token", "DPT")
        Ownable(initialOwner)
    {
        // Mint initial allocation to owner for bootstrapping (10%)
        _mint(initialOwner, 10_000_000 * 1e18);
    }

    /**
     * @notice Mint tokens (only LiquidityMining contract as owner)
     * @param to Recipient
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        require(totalSupply() + amount <= MAX_SUPPLY, "GovernanceToken: cap exceeded");
        _mint(to, amount);
    }
}
