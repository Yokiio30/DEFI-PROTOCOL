// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/LendingPool.sol";
import "../src/LiquidityMining.sol";
import "../src/Governance.sol";
import "../src/GovernanceToken.sol";

/**
 * @notice Deploy the full DeFi Protocol Suite
 *
 * Usage:
 *   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
 *
 * Environment variables:
 *   DEPLOYER_PRIVATE_KEY  — deployer wallet private key
 *   GUARDIAN_ADDRESS      — emergency multi-sig address
 */
contract DeployScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address guardian = vm.envOr("GUARDIAN_ADDRESS", deployer);

        console.log("Deployer:     ", deployer);
        console.log("Guardian:     ", guardian);
        console.log("Chain ID:     ", block.chainid);

        vm.startBroadcast(deployerKey);

        // ── 1. Governance Token (non-upgradeable) ──
        GovernanceToken govToken = new GovernanceToken(deployer);
        console.log("GovernanceToken:", address(govToken));

        // ── 2. LendingPool (UUPS proxy) ──
        LendingPool poolImpl = new LendingPool();
        bytes memory poolInit = abi.encodeWithSelector(
            LendingPool.initialize.selector,
            deployer
        );
        ERC1967Proxy poolProxy = new ERC1967Proxy(address(poolImpl), poolInit);
        LendingPool pool = LendingPool(address(poolProxy));
        console.log("LendingPool (proxy):", address(pool));
        console.log("LendingPool (impl): ", address(poolImpl));

        // ── 3. LiquidityMining (UUPS proxy) ──
        LiquidityMining miningImpl = new LiquidityMining();
        bytes memory miningInit = abi.encodeWithSelector(
            LiquidityMining.initialize.selector,
            deployer
        );
        ERC1967Proxy miningProxy = new ERC1967Proxy(address(miningImpl), miningInit);
        LiquidityMining mining = LiquidityMining(address(miningProxy));
        console.log("LiquidityMining (proxy):", address(mining));

        // ── 4. Governance (UUPS proxy) ──
        Governance govImpl = new Governance();
        bytes memory govInit = abi.encodeWithSelector(
            Governance.initialize.selector,
            address(govToken),   // governance token
            1 hours,             // timelock delay  (shortened for demo; prod: 2 days)
            5 minutes,           // voting delay    (shortened for demo; prod: 1 hour)
            30 minutes,          // voting period   (shortened for demo; prod: 3 days)
            1_000 ether,         // proposal threshold (1000 DPT)
            10_000 ether,        // quorum (10,000 DPT)
            guardian,            // emergency guardian
            deployer             // initial owner
        );
        ERC1967Proxy govProxy = new ERC1967Proxy(address(govImpl), govInit);
        Governance gov = Governance(payable(address(govProxy)));
        console.log("Governance (proxy):", address(gov));

        // ── 5. Register assets in LendingPool ──
        // Sepolia WETH: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
        // Sepolia USDC: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
        address sepoliaWETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
        address sepoliaUSDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
        // collateralFactor=75%, liquidationThreshold=80%, penalty=5%, reserveFactor=10%
        pool.addAsset(sepoliaWETH, 7500, 8000, 500, 1000);
        pool.addAsset(sepoliaUSDC, 7500, 8000, 500, 1000);
        console.log("Assets registered: WETH + USDC");

        // ── 6. Add mining pools for WETH and USDC staking ──
        mining.addPool(sepoliaWETH, 100); // WETH pool: 2x weight
        mining.addPool(sepoliaUSDC, 50);  // USDC pool: 1x weight

        // ── 7. Bootstrap: Fund LiquidityMining with reward tokens ──
        uint256 rewardSupply = 50_000_000 ether; // 50M DPT for rewards
        govToken.mint(address(mining), rewardSupply);

        // Add DPT as a reward token (90-day emission)
        mining.addRewardToken(
            address(govToken),
            5787037037037, // ~500 DPT/day = 500e18 / 86400
            block.timestamp,
            block.timestamp + 90 days
        );

        // ── 8. Transfer ownerships to governance ──
        // In production: transfer to gov address so upgrades require proposals
        // For testnet: keep deployer as owner for easy testing
        // pool.transferOwnership(address(gov));
        // mining.transferOwnership(address(gov));

        vm.stopBroadcast();

        // ── Summary ──
        console.log("\n========== DEPLOYMENT SUMMARY ==========");
        console.log("GovernanceToken: ", address(govToken));
        console.log("LendingPool:     ", address(pool));
        console.log("LiquidityMining: ", address(mining));
        console.log("Governance:      ", address(gov));
        console.log("=========================================");
    }
}
