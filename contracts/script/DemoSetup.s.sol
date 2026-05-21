// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/LendingPool.sol";
import "../src/LiquidityMining.sol";
import "../src/Governance.sol";
import "../src/GovernanceToken.sol";

/// @dev Mintable mock token for local demo
contract MockToken is ERC20 {
    uint8 private _dec;
    constructor(string memory name, string memory symbol, uint8 dec) ERC20(name, symbol) {
        _dec = dec;
    }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/**
 * @notice One-shot local demo deployment.
 *
 * Usage (from contracts/):
 *   anvil &                           # terminal 1 — keep running
 *   forge script script/DemoSetup.s.sol --rpc-url http://localhost:8545 --broadcast
 *
 * Anvil account 0 private key (always the same):
 *   0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
 */
contract DemoSetupScript is Script {
    // Anvil account 0 — always available on local node
    uint256 constant DEMO_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        address deployer = vm.addr(DEMO_KEY);
        // Anvil account 1 — second demo user
        address alice = vm.addr(0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d);

        console.log("=== DeFi Protocol Demo Setup ===");
        console.log("Deployer:", deployer);
        console.log("Alice:   ", alice);

        vm.startBroadcast(DEMO_KEY);

        // ── 1. Mock ERC20 tokens ──────────────────────────────────────────
        MockToken weth = new MockToken("Wrapped Ether", "WETH", 18);
        MockToken usdc = new MockToken("USD Coin", "USDC", 6);

        // Mint demo balances to deployer and alice
        weth.mint(deployer, 100 ether);
        weth.mint(alice,    50 ether);
        usdc.mint(deployer, 200_000e6);
        usdc.mint(alice,    100_000e6);

        console.log("\n--- Mock Tokens ---");
        console.log("WETH:", address(weth));
        console.log("USDC:", address(usdc));

        // ── 2. Governance Token ───────────────────────────────────────────
        GovernanceToken govToken = new GovernanceToken(deployer);
        // Give alice enough to propose and vote
        govToken.transfer(alice, 50_000 ether);
        console.log("GovernanceToken:", address(govToken));

        // ── 3. LendingPool ────────────────────────────────────────────────
        LendingPool poolImpl = new LendingPool();
        ERC1967Proxy poolProxy = new ERC1967Proxy(
            address(poolImpl),
            abi.encodeWithSelector(LendingPool.initialize.selector, deployer)
        );
        LendingPool pool = LendingPool(address(poolProxy));

        // Register both assets
        pool.addAsset(address(weth), 7500, 8000, 500, 1000); // 75% CF, 80% LT, 5% penalty, 10% reserve
        pool.addAsset(address(usdc), 7500, 8000, 500, 1000);

        console.log("LendingPool:", address(pool));

        // ── 4. LiquidityMining ────────────────────────────────────────────
        LiquidityMining miningImpl = new LiquidityMining();
        ERC1967Proxy miningProxy = new ERC1967Proxy(
            address(miningImpl),
            abi.encodeWithSelector(LiquidityMining.initialize.selector, deployer)
        );
        LiquidityMining mining = LiquidityMining(address(miningProxy));

        // Add WETH and USDC staking pools
        mining.addPool(address(weth), 100); // WETH pool: 100 alloc points
        mining.addPool(address(usdc), 50);  // USDC pool:  50 alloc points

        // Fund mining with DPT rewards and schedule 90-day emission
        uint256 rewardSupply = 50_000_000 ether;
        govToken.mint(address(mining), rewardSupply);
        mining.addRewardToken(
            address(govToken),
            5787037037037,         // ~500 DPT/day
            block.timestamp + 60,  // 60s buffer: script sim vs broadcast lag
            block.timestamp + 60 + 90 days
        );

        console.log("LiquidityMining:", address(mining));

        // ── 5. Governance ─────────────────────────────────────────────────
        Governance govImpl = new Governance();
        ERC1967Proxy govProxy = new ERC1967Proxy(
            address(govImpl),
            abi.encodeWithSelector(
                Governance.initialize.selector,
                address(govToken),
                2 days,        // timelock
                1 hours,       // voting delay
                3 days,        // voting period
                1_000 ether,   // proposal threshold
                10_000 ether,  // quorum
                deployer,      // guardian
                deployer       // owner
            )
        );
        Governance gov = Governance(payable(address(govProxy)));
        console.log("Governance:", address(gov));

        vm.stopBroadcast();

        // ── Summary (copy these into frontend/.env) ───────────────────────
        console.log("\n====== COPY TO frontend/.env ======");
        console.log("VITE_LENDING_POOL_ADDRESS=", address(pool));
        console.log("VITE_MINING_ADDRESS=", address(mining));
        console.log("VITE_GOVERNANCE_ADDRESS=", address(gov));
        console.log("VITE_GOV_TOKEN_ADDRESS=", address(govToken));
        console.log("VITE_WETH_ADDRESS=", address(weth));
        console.log("VITE_USDC_ADDRESS=", address(usdc));
        console.log("====================================");
    }
}
