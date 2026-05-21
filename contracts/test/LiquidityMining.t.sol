// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/LiquidityMining.sol";

// Mock LP token
contract MockLPToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// V2 for upgrade test
contract LiquidityMiningV2 is LiquidityMining {
    function version() external pure override returns (string memory) {
        return "2.0.0";
    }
}

contract LiquidityMiningTest is Test {
    LiquidityMining public mining;
    ERC1967Proxy public proxy;
    MockLPToken public lpTokenA;
    MockLPToken public lpTokenB;
    MockLPToken public rewardToken;

    address public owner = address(0x1);
    address public alice = address(0x2);
    address public bob   = address(0x3);
    address public carol = address(0x4);

    uint256 constant STAKE_AMOUNT = 1000 ether;

    function setUp() public {
        // Deploy tokens
        lpTokenA = new MockLPToken("LP Token A", "LPA");
        lpTokenB = new MockLPToken("LP Token B", "LPB");
        rewardToken = new MockLPToken("Reward Token", "RWD");

        // Deploy implementation + proxy
        LiquidityMining implementation = new LiquidityMining();
        bytes memory initData = abi.encodeWithSelector(
            LiquidityMining.initialize.selector,
            owner
        );
        proxy = new ERC1967Proxy(address(implementation), initData);
        mining = LiquidityMining(address(proxy));

        // Fund reward tokens to the mining contract
        rewardToken.mint(address(mining), 10_000_000 ether);

        // Mint LP tokens to users and approve
        vm.startPrank(owner);
        mining.addRewardToken(address(rewardToken), 0.1 ether, block.timestamp, block.timestamp + 365 days);
        mining.addPool(address(lpTokenA), 100);
        mining.addPool(address(lpTokenB), 50);
        vm.stopPrank();

        lpTokenA.mint(alice, 10_000 ether);
        lpTokenA.mint(bob,   10_000 ether);
        lpTokenB.mint(carol, 10_000 ether);

        vm.prank(alice); lpTokenA.approve(address(mining), type(uint256).max);
        vm.prank(bob);   lpTokenA.approve(address(mining), type(uint256).max);
        vm.prank(carol); lpTokenB.approve(address(mining), type(uint256).max);
    }

    // ─── Initialization ──────────────────────────────────────────

    function test_InitialState() public view {
        assertEq(mining.owner(), owner);
        assertEq(mining.version(), "1.0.0");
        assertEq(mining.poolLength(), 2);
        assertEq(mining.rewardTokenLength(), 1);
        assertEq(mining.totalAllocPoint(), 150);
    }

    function test_CannotInitializeTwice() public {
        vm.expectRevert();
        mining.initialize(owner);
    }

    // ─── Pool Management ─────────────────────────────────────────

    function test_AddPool() public {
        MockLPToken newLP = new MockLPToken("New LP", "NLP");
        vm.prank(owner);
        mining.addPool(address(newLP), 25);

        assertEq(mining.poolLength(), 3);
        assertEq(mining.totalAllocPoint(), 175);
    }

    function test_AddPool_ZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert("LiquidityMining: zero address");
        mining.addPool(address(0), 50);
    }

    function test_AddPool_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        mining.addPool(address(lpTokenA), 50);
    }

    function test_SetPool() public {
        vm.prank(owner);
        mining.setPool(0, 200);
        (, uint256 allocPoint,,,) = mining.poolInfo(0);
        assertEq(allocPoint, 200);
        assertEq(mining.totalAllocPoint(), 250);
    }

    // ─── Reward Token Management ─────────────────────────────────

    function test_AddRewardToken() public {
        MockLPToken newRwd = new MockLPToken("New Rwd", "NRWD");
        vm.prank(owner);
        mining.addRewardToken(address(newRwd), 2 ether, block.timestamp, block.timestamp + 90 days);
        assertEq(mining.rewardTokenLength(), 2);
    }

    function test_AddRewardToken_InvalidSchedule() public {
        MockLPToken newRwd = new MockLPToken("New Rwd", "NRWD");
        vm.prank(owner);
        vm.expectRevert("LiquidityMining: invalid schedule");
        mining.addRewardToken(address(newRwd), 1 ether, block.timestamp, block.timestamp); // end == start
    }

    // ─── Stake ────────────────────────────────────────────────────

    function test_Stake_Success() public {
        vm.prank(alice);
        mining.stake(0, STAKE_AMOUNT);

        (uint256 amount,,) = mining.userInfo(0, alice);
        assertEq(amount, STAKE_AMOUNT);

        (,,, uint256 accPerShare, uint256 totalStaked) = mining.poolInfo(0);
        assertEq(totalStaked, STAKE_AMOUNT);
    }

    function test_Stake_ZeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert("LiquidityMining: zero amount");
        mining.stake(0, 0);
    }

    // ─── Unstake ──────────────────────────────────────────────────

    function test_Unstake_Success() public {
        vm.prank(alice);
        mining.stake(0, STAKE_AMOUNT);

        vm.prank(alice);
        mining.unstake(0, STAKE_AMOUNT);

        (uint256 amount,,) = mining.userInfo(0, alice);
        assertEq(amount, 0);

        (,,, uint256 accPerShare, uint256 totalStaked) = mining.poolInfo(0);
        assertEq(totalStaked, 0);
    }

    function test_Unstake_InsufficientReverts() public {
        vm.prank(alice);
        vm.expectRevert("LiquidityMining: insufficient stake");
        mining.unstake(0, 100 ether);
    }

    // ─── Harvest ──────────────────────────────────────────────────

    function test_Harvest_EarnsRewards() public {
        vm.prank(alice);
        mining.stake(0, STAKE_AMOUNT);

        // Skip 30 days
        vm.warp(block.timestamp + 30 days);

        uint256 pendingBefore = mining.pendingReward(0, alice);
        assertGt(pendingBefore, 0, "Should have pending rewards after staking");

        uint256 balBefore = rewardToken.balanceOf(alice);
        vm.prank(alice);
        mining.harvest(0, 0);
        uint256 balAfter = rewardToken.balanceOf(alice);

        assertGt(balAfter - balBefore, 0, "Should receive rewards from harvest");
    }

    function test_Harvest_MultipleHarvests() public {
        vm.prank(alice);
        mining.stake(0, STAKE_AMOUNT);

        // First harvest after 10 days
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        mining.harvest(0, 0);
        uint256 firstHarvest = rewardToken.balanceOf(alice);
        assertGt(firstHarvest, 0, "First harvest should yield rewards");

        // After harvest, pending should be reset
        uint256 pendingAfterHarvest = mining.pendingReward(0, alice);
        assertLt(pendingAfterHarvest, firstHarvest, "Pending should be small after harvest");
    }

    // ─── Reward Distribution ──────────────────────────────────────

    function test_RewardProportionalToAllocPoints() public {
        // Alice stakes in pool 0 (100 alloc), Bob stakes in pool 1 (50 alloc)
        lpTokenB.mint(bob, 10_000 ether);
        vm.prank(bob); lpTokenB.approve(address(mining), type(uint256).max);

        vm.prank(alice);
        mining.stake(0, STAKE_AMOUNT);

        vm.prank(bob);
        mining.stake(1, STAKE_AMOUNT);

        vm.warp(block.timestamp + 30 days);

        uint256 aliceReward = mining.pendingReward(0, alice);
        uint256 bobReward = mining.pendingReward(1, bob);

        // Pool 0 (100 alloc) should earn ~2x of pool 1 (50 alloc)
        assertApproxEqRel(aliceReward, bobReward * 2, 0.01e18); // within 1%
    }

    // ─── Multi-User ───────────────────────────────────────────────

    function test_MultiUser_SamePool() public {
        vm.prank(alice);
        mining.stake(0, 700 ether);

        vm.prank(bob);
        mining.stake(0, 300 ether);

        vm.warp(block.timestamp + 30 days);

        uint256 aliceReward = mining.pendingReward(0, alice);
        uint256 bobReward = mining.pendingReward(0, bob);

        // Alice (70%) should get ~2.33x of Bob (30%)
        assertApproxEqRel(aliceReward * 3, bobReward * 7, 0.01e18);
    }

    // ─── Emergency Withdraw ───────────────────────────────────────

    function test_EmergencyWithdraw() public {
        vm.prank(alice);
        mining.stake(0, STAKE_AMOUNT);

        uint256 balBefore = lpTokenA.balanceOf(alice);

        vm.prank(alice);
        mining.emergencyWithdraw(0);

        uint256 balAfter = lpTokenA.balanceOf(alice);

        assertEq(balAfter - balBefore, STAKE_AMOUNT, "Should return all staked tokens");

        (uint256 amount,,) = mining.userInfo(0, alice);
        assertEq(amount, 0, "User stake should be zero");
    }

    function test_EmergencyWithdraw_ResetsRewards() public {
        vm.prank(alice);
        mining.stake(0, STAKE_AMOUNT);

        vm.warp(block.timestamp + 30 days);

        vm.prank(alice);
        mining.emergencyWithdraw(0);

        // After emergency withdraw, pending rewards should be zero
        uint256 pending = mining.pendingReward(0, alice);
        assertEq(pending, 0, "Pending rewards should be zero after emergency withdraw");
    }

    // ─── Pause ────────────────────────────────────────────────────

    function test_Pause_BlocksStake() public {
        vm.prank(owner);
        mining.pause();

        vm.prank(alice);
        vm.expectRevert();
        mining.stake(0, STAKE_AMOUNT);
    }

    function test_Pause_OnlyOwner() public {
        vm.expectRevert();
        mining.pause();
    }

    function test_Unpause_AllowsStakeAgain() public {
        vm.prank(owner);
        mining.pause();
        vm.prank(owner);
        mining.unpause();

        vm.prank(alice);
        mining.stake(0, STAKE_AMOUNT);
        (uint256 amount,,) = mining.userInfo(0, alice);
        assertEq(amount, STAKE_AMOUNT);
    }

    // ─── Pending Reward View ──────────────────────────────────────

    function test_PendingReward_WithoutStake() public view {
        uint256 pending = mining.pendingReward(0, alice);
        assertEq(pending, 0);
    }

    function test_PendingReward_AccumulatesAfterStake() public {
        vm.prank(alice);
        mining.stake(0, STAKE_AMOUNT);

        // Pending should be 0 immediately after staking
        uint256 pending0 = mining.pendingReward(0, alice);
        assertEq(pending0, 0, "No pending immediately after stake");

        // After 10 days, pending should be positive
        vm.warp(block.timestamp + 10 days);
        uint256 pending10d = mining.pendingReward(0, alice);
        assertGt(pending10d, 0, "Pending should accumulate over time");
    }

    // ─── UUPS Upgrade ─────────────────────────────────────────────

    function test_Upgrade_V2KeepsState() public {
        vm.prank(alice);
        mining.stake(0, STAKE_AMOUNT);
        (uint256 sharesBefore,,) = mining.userInfo(0, alice);

        // Upgrade
        LiquidityMiningV2 implV2 = new LiquidityMiningV2();
        vm.prank(owner);
        mining.upgradeToAndCall(address(implV2), "");

        LiquidityMiningV2 miningV2 = LiquidityMiningV2(address(proxy));
        (uint256 sharesAfter,,) = miningV2.userInfo(0, alice);
        assertEq(sharesAfter, sharesBefore, "State preserved after upgrade");
        assertEq(miningV2.version(), "2.0.0");
    }

    function test_Upgrade_OnlyOwner() public {
        LiquidityMiningV2 implV2 = new LiquidityMiningV2();
        vm.prank(alice);
        vm.expectRevert();
        mining.upgradeToAndCall(address(implV2), "");
    }

    // ─── Fuzz ─────────────────────────────────────────────────────

    function testFuzz_Stake_AnyAmount(uint256 amount) public {
        amount = bound(amount, 1, 5000 ether);
        vm.prank(alice);
        mining.stake(0, amount);

        (uint256 staked,,) = mining.userInfo(0, alice);
        assertEq(staked, amount);
    }

    function testFuzz_PendingReward_NeverDecreases(uint256 timeDelta) public {
        timeDelta = bound(timeDelta, 1 days, 180 days);

        vm.prank(alice);
        mining.stake(0, STAKE_AMOUNT);

        uint256 pendingBefore = mining.pendingReward(0, alice);

        vm.warp(block.timestamp + timeDelta);

        uint256 pendingAfter = mining.pendingReward(0, alice);
        assertGe(pendingAfter, pendingBefore, "Pending reward should be monotonic");
    }

    // ─── Bug Fix: Per-Token Reward Independence ───────────────────

    function test_TwoRewardTokens_AccountedSeparately() public {
        MockLPToken rewardToken2 = new MockLPToken("Reward Token 2", "RWD2");
        rewardToken2.mint(address(mining), 10_000_000 ether);
        vm.prank(owner);
        // rate is half of token 0 (0.05 vs 0.1 ether/s)
        mining.addRewardToken(address(rewardToken2), 0.05 ether, block.timestamp, block.timestamp + 365 days);

        vm.prank(alice);
        mining.stake(0, STAKE_AMOUNT);

        vm.warp(block.timestamp + 30 days);

        uint256 pending0 = mining.pendingRewardByToken(0, alice, 0);
        uint256 pending1 = mining.pendingRewardByToken(0, alice, 1);
        assertGt(pending0, 0, "Token 0 pending must be non-zero");
        assertGt(pending1, 0, "Token 1 pending must be non-zero");
        // Token 0 at 2x rate should yield ~2x rewards
        assertApproxEqRel(pending0, pending1 * 2, 0.01e18);

        // Harvest token 0 — token 1 balance must be untouched
        uint256 rwd2Before = rewardToken2.balanceOf(alice);
        vm.prank(alice);
        mining.harvest(0, 0);
        assertEq(rewardToken2.balanceOf(alice), rwd2Before, "Token 1 balance must not change");

        // Token 1 pending should still be non-zero after harvesting token 0
        assertGt(mining.pendingRewardByToken(0, alice, 1), 0, "Token 1 pending must survive");
    }

    function test_Harvest_InvalidTokenIndex_Reverts() public {
        vm.prank(alice);
        mining.stake(0, STAKE_AMOUNT);
        vm.prank(alice);
        vm.expectRevert("LiquidityMining: invalid reward token");
        mining.harvest(0, 99);
    }

    function test_PendingRewardByToken_EqualsTotalWhenOneToken() public {
        vm.prank(alice);
        mining.stake(0, STAKE_AMOUNT);
        vm.warp(block.timestamp + 20 days);

        uint256 total   = mining.pendingReward(0, alice);
        uint256 byToken = mining.pendingRewardByToken(0, alice, 0);
        assertEq(total, byToken, "With 1 reward token, total must equal per-token");
    }

    function test_AddRewardToken_ZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert("LiquidityMining: zero address");
        mining.addRewardToken(address(0), 1 ether, block.timestamp, block.timestamp + 1 days);
    }

    function test_AddRewardToken_StartInPastReverts() public {
        vm.warp(1000); // advance time so there's a clear "past"
        vm.prank(owner);
        vm.expectRevert("LiquidityMining: start in past");
        mining.addRewardToken(address(rewardToken), 1 ether, 999, 2000);
    }

    function testFuzz_Harvest_AfterMultipleStakes(uint256 stake1, uint256 stake2, uint256 delta) public {
        stake1 = bound(stake1, 1 ether, 5000 ether);
        stake2 = bound(stake2, 1 ether, 5000 ether);
        delta  = bound(delta, 1 days, 90 days);

        lpTokenA.mint(alice, stake1 + stake2);
        vm.prank(alice);
        lpTokenA.approve(address(mining), type(uint256).max);

        vm.prank(alice);
        mining.stake(0, stake1);
        vm.warp(block.timestamp + delta);
        vm.prank(alice);
        mining.stake(0, stake2);
        vm.warp(block.timestamp + delta);

        uint256 balBefore = rewardToken.balanceOf(alice);
        vm.prank(alice);
        mining.harvest(0, 0);
        assertGt(rewardToken.balanceOf(alice) - balBefore, 0, "Must earn rewards");
    }

    // ─── Invariant ────────────────────────────────────────────────

    function invariant_PerTokenDebtNeverExceedsEarnable() public view {
        uint256 numPools  = mining.poolLength();
        uint256 numTokens = mining.rewardTokenLength();
        address[3] memory stakers = [alice, bob, carol];

        for (uint256 p = 0; p < numPools; p++) {
            for (uint256 t = 0; t < numTokens; t++) {
                uint256 acc = mining.accRewardPerShareByToken(p, t);
                for (uint256 u = 0; u < stakers.length; u++) {
                    (uint256 amount,,) = mining.userInfo(p, stakers[u]);
                    uint256 debt = mining.userRewardDebtByToken(p, stakers[u], t);
                    // debt is set to amount * acc / PRECISION right after stake/harvest,
                    // so it should never exceed that ceiling (+1 for rounding)
                    assertLe(debt, amount * acc / mining.PRECISION() + 1, "Debt exceeds ceiling");
                }
            }
        }
    }

    // ─── Integration: Full Flow ───────────────────────────────────

    function test_FullFlow_StakeHarvestUnstake() public {
        // Alice stakes
        vm.prank(alice);
        mining.stake(0, STAKE_AMOUNT);

        // Time passes
        vm.warp(block.timestamp + 30 days);

        // Harvest rewards
        uint256 balBefore = rewardToken.balanceOf(alice);
        vm.prank(alice);
        mining.harvest(0, 0);
        uint256 harvested = rewardToken.balanceOf(alice) - balBefore;
        assertGt(harvested, 0);

        // Unstake everything
        uint256 lpBalBefore = lpTokenA.balanceOf(alice);
        vm.prank(alice);
        mining.unstake(0, STAKE_AMOUNT);
        uint256 lpBalAfter = lpTokenA.balanceOf(alice);

        assertEq(lpBalAfter - lpBalBefore, STAKE_AMOUNT, "Full LP tokens returned");
    }
}
