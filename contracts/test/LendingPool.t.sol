// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/LendingPool.sol";

// ─────────────────────────────────────────────
// Mock ERC-20 for testing
// ─────────────────────────────────────────────
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ─────────────────────────────────────────────
// V2 implementation to test upgrade path
// ─────────────────────────────────────────────
contract LendingPoolV2 is LendingPool {
    function version() external pure override returns (string memory) {
        return "2.0.0";
    }
    function newFeatureV2() external pure returns (bool) {
        return true;
    }
}

// ─────────────────────────────────────────────
// Main Test Suite
// ─────────────────────────────────────────────
contract LendingPoolTest is Test {
    LendingPool public pool;
    ERC1967Proxy public proxy;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address public owner = address(0x1);
    address public alice = address(0x2);
    address public bob   = address(0x3);
    address public carol = address(0x4); // liquidator

    uint256 constant CF  = 7500;   // 75% collateral factor
    uint256 constant LT  = 8000;   // 80% liquidation threshold
    uint256 constant LP  = 500;    // 5% liquidation penalty
    uint256 constant RF  = 1000;   // 10% reserve factor
    uint256 constant DEPOSIT = 1000 ether;

    function setUp() public {
        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");

        // Deploy implementation + proxy
        LendingPool implementation = new LendingPool();
        bytes memory initData = abi.encodeWithSelector(
            LendingPool.initialize.selector,
            owner
        );
        proxy = new ERC1967Proxy(address(implementation), initData);
        pool = LendingPool(address(proxy));

        // Add assets as owner
        vm.startPrank(owner);
        pool.addAsset(address(tokenA), CF, LT, LP, RF);
        pool.addAsset(address(tokenB), CF, LT, LP, RF);
        vm.stopPrank();

        // Mint tokens to users
        tokenA.mint(alice,  10_000 ether);
        tokenA.mint(bob,    10_000 ether);
        tokenA.mint(carol,  10_000 ether);
        tokenB.mint(alice,  10_000 ether);
        tokenB.mint(bob,    10_000 ether);
        tokenB.mint(carol,  10_000 ether);

        // Approve pool
        vm.prank(alice); tokenA.approve(address(pool), type(uint256).max);
        vm.prank(alice); tokenB.approve(address(pool), type(uint256).max);
        vm.prank(bob);   tokenA.approve(address(pool), type(uint256).max);
        vm.prank(bob);   tokenB.approve(address(pool), type(uint256).max);
        vm.prank(carol); tokenA.approve(address(pool), type(uint256).max);
        vm.prank(carol); tokenB.approve(address(pool), type(uint256).max);
    }

    // ─── Initialization ────────────────────────────────────────────

    function test_InitialState() public view {
        assertEq(pool.owner(), owner);
        assertEq(pool.version(), "1.0.0");

        address[] memory assets = pool.getSupportedAssets();
        assertEq(assets.length, 2);
        assertEq(assets[0], address(tokenA));
        assertEq(assets[1], address(tokenB));
    }

    function test_CannotInitializeTwice() public {
        vm.expectRevert();
        pool.initialize(owner);
    }

    // ─── Asset Management ──────────────────────────────────────────

    function test_AddAsset_OnlyOwner() public {
        address randomToken = address(new MockERC20("X", "X"));
        vm.expectRevert();
        pool.addAsset(randomToken, CF, LT, LP, RF);
    }

    function test_AddAsset_DuplicateReverts() public {
        vm.prank(owner);
        vm.expectRevert("LendingPool: already supported");
        pool.addAsset(address(tokenA), CF, LT, LP, RF);
    }

    function test_AddAsset_CFMustBeLowerThanLT() public {
        address t = address(new MockERC20("T", "T"));
        vm.prank(owner);
        vm.expectRevert("LendingPool: CF >= LT");
        pool.addAsset(t, 8500, 8000, LP, RF);
    }

    // ─── Deposit ───────────────────────────────────────────────────

    function test_Deposit_ReceivesShares() public {
        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        uint256 shares = pool.getDepositShares(alice, address(tokenA));
        assertGt(shares, 0, "Should receive deposit shares");

        uint256 balance = pool.getDepositBalance(alice, address(tokenA));
        // Initial balance should equal deposit (before interest accrual)
        assertApproxEqAbs(balance, DEPOSIT, 1);
    }

    function test_Deposit_ZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert("LendingPool: zero amount");
        pool.deposit(address(tokenA), 0);
    }

    function test_Deposit_UnsupportedAssetReverts() public {
        address unknown = address(new MockERC20("U", "U"));
        vm.prank(alice);
        vm.expectRevert("LendingPool: unsupported asset");
        pool.deposit(unknown, DEPOSIT);
    }

    function testFuzz_Deposit_AnyAmount(uint256 amount) public {
        amount = bound(amount, 1, 10_000 ether);
        tokenA.mint(alice, amount);
        vm.prank(alice);
        tokenA.approve(address(pool), amount);
        vm.prank(alice);
        pool.deposit(address(tokenA), amount);

        uint256 balance = pool.getDepositBalance(alice, address(tokenA));
        assertApproxEqAbs(balance, amount, 1);
    }

    // ─── Withdraw ──────────────────────────────────────────────────

    function test_Withdraw_ReturnsTokens() public {
        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        uint256 shares = pool.getDepositShares(alice, address(tokenA));
        uint256 balanceBefore = tokenA.balanceOf(alice);

        vm.prank(alice);
        pool.withdraw(address(tokenA), shares);

        uint256 balanceAfter = tokenA.balanceOf(alice);
        assertApproxEqAbs(balanceAfter - balanceBefore, DEPOSIT, 1);
    }

    function test_Withdraw_WithAccruedInterest() public {
        // Alice deposits, bob borrows, time passes, alice withdraws more than deposited
        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        vm.prank(bob);
        pool.deposit(address(tokenA), DEPOSIT); // add liquidity for bob to borrow

        vm.prank(bob);
        pool.borrow(address(tokenA), 500 ether);

        // Skip 30 days
        vm.warp(block.timestamp + 30 days);

        uint256 aliceShares = pool.getDepositShares(alice, address(tokenA));
        uint256 aliceBalance = pool.getDepositBalance(alice, address(tokenA));
        assertGe(aliceBalance, DEPOSIT, "Alice should have earned interest");
    }

    function test_Withdraw_InsufficientSharesReverts() public {
        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        uint256 shares = pool.getDepositShares(alice, address(tokenA));
        vm.prank(alice);
        vm.expectRevert("LendingPool: insufficient shares");
        pool.withdraw(address(tokenA), shares + 1);
    }

    // ─── Borrow ────────────────────────────────────────────────────

    function test_Borrow_RequiresCollateral() public {
        // Alice deposits tokenA as collateral, borrows tokenB
        vm.prank(bob);
        pool.deposit(address(tokenB), DEPOSIT); // liquidity for tokenB

        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        vm.prank(alice);
        pool.borrow(address(tokenB), 600 ether); // borrow 60% of 1000 (within 75% CF)

        uint256 debt = pool.getBorrowBalance(alice, address(tokenB));
        assertApproxEqAbs(debt, 600 ether, 1);
    }

    function test_Borrow_ExceedsCFReverts() public {
        vm.prank(bob);
        pool.deposit(address(tokenB), DEPOSIT);

        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        // Try to borrow 90% — exceeds 75% collateral factor
        vm.prank(alice);
        vm.expectRevert("LendingPool: undercollateralized");
        pool.borrow(address(tokenB), 900 ether);
    }

    function test_Borrow_ExceedsLiquidityReverts() public {
        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        vm.prank(alice);
        vm.expectRevert("LendingPool: insufficient liquidity");
        pool.borrow(address(tokenA), DEPOSIT + 1);
    }

    // ─── Repay ─────────────────────────────────────────────────────

    function test_Repay_ClearsDebt() public {
        vm.prank(bob);
        pool.deposit(address(tokenB), DEPOSIT);

        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        vm.prank(alice);
        pool.borrow(address(tokenB), 500 ether);

        uint256 borrowShares = pool.getBorrowShares(alice, address(tokenB));
        vm.prank(alice);
        pool.repay(address(tokenB), borrowShares);

        uint256 remainingDebt = pool.getBorrowBalance(alice, address(tokenB));
        assertEq(remainingDebt, 0);
    }

    function test_Repay_NoDebtReverts() public {
        vm.prank(alice);
        vm.expectRevert("LendingPool: no debt");
        pool.repay(address(tokenA), 1);
    }

    // ─── Interest Accrual ──────────────────────────────────────────

    function test_InterestAccrual_BorrowDebtGrows() public {
        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        vm.prank(alice);
        pool.borrow(address(tokenA), 500 ether);

        uint256 debtBefore = pool.getBorrowBalance(alice, address(tokenA));

        // Warp time — but indexes only update on state-changing calls
        vm.warp(block.timestamp + 365 days);

        // Trigger index update via a tiny deposit from bob
        vm.prank(bob);
        pool.deposit(address(tokenA), 1);

        uint256 debtAfter = pool.getBorrowBalance(alice, address(tokenA));
        assertGt(debtAfter, debtBefore, "Debt should grow over time");
    }

    function test_InterestRate_IncreasesWithUtilization() public {
        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        uint256 rateLow = pool.getBorrowRate(address(tokenA));

        vm.prank(alice);
        pool.borrow(address(tokenA), 800 ether); // 80% utilization (at kink)

        uint256 rateHigh = pool.getBorrowRate(address(tokenA));
        assertGt(rateHigh, rateLow, "Rate should increase with utilization");
    }

    // ─── Health Factor ─────────────────────────────────────────────

    function test_HealthFactor_NoDebtIsMaxUint() public {
        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        uint256 hf = pool.healthFactor(alice);
        assertEq(hf, type(uint256).max);
    }

    function test_HealthFactor_BelowOneAfterPriceDrop() public {
        // Simulate by borrowing near max and time-warping (interest drives HF below 1)
        vm.prank(bob);
        pool.deposit(address(tokenA), 10_000 ether);

        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        vm.prank(alice);
        pool.borrow(address(tokenA), 745 ether); // near max CF of 75%

        // Fast forward 4 years — interest accrual pushes HF below 1
        vm.warp(block.timestamp + 1460 days);

        // Trigger index update via alice
        vm.prank(alice);
        pool.deposit(address(tokenA), 1);

        uint256 hf = pool.healthFactor(alice);
        assertLt(hf, 1e18, "Health factor should be below 1");
    }

    // ─── Liquidation ───────────────────────────────────────────────

    function test_Liquidation_HealthyPositionReverts() public {
        vm.prank(bob);
        pool.deposit(address(tokenA), DEPOSIT);

        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        vm.prank(alice);
        pool.borrow(address(tokenA), 500 ether);

        vm.prank(carol);
        vm.expectRevert("LendingPool: healthy position");
        pool.liquidate(alice, address(tokenA), address(tokenA), 1);
    }

    function test_Liquidation_Succeeds() public {
        vm.prank(bob);
        pool.deposit(address(tokenA), 10_000 ether);

        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        vm.prank(alice);
        pool.borrow(address(tokenA), 745 ether);

        // Time warp to make unhealthy
        vm.warp(block.timestamp + 1460 days);

        // Trigger index update
        vm.prank(alice);
        pool.deposit(address(tokenA), 1);

        uint256 carolBalanceBefore = tokenA.balanceOf(carol);

        uint256 aliceDebtShares = pool.getBorrowShares(alice, address(tokenA));
        vm.prank(carol);
        pool.liquidate(alice, address(tokenA), address(tokenA), aliceDebtShares / 2);

        uint256 carolBalanceAfter = tokenA.balanceOf(carol);
        // Carol should have spent some tokens but received collateral + bonus
        // Net: carolBalanceAfter may be < before due to debt repayment, but seized more
        assertTrue(carolBalanceAfter != carolBalanceBefore, "Liquidator balance should change");
    }

    // ─── Pause ─────────────────────────────────────────────────────

    function test_Pause_BlocksDeposit() public {
        vm.prank(owner);
        pool.pause();

        vm.prank(alice);
        vm.expectRevert();
        pool.deposit(address(tokenA), DEPOSIT);
    }

    function test_Unpause_RestoresDeposit() public {
        vm.prank(owner);
        pool.pause();

        vm.prank(owner);
        pool.unpause();

        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);
        assertGt(pool.getDepositShares(alice, address(tokenA)), 0);
    }

    function test_Pause_OnlyOwner() public {
        vm.expectRevert();
        pool.pause();
    }

    // ─── UUPS Upgrade ──────────────────────────────────────────────

    function test_Upgrade_V2KeepsState() public {
        // Deposit before upgrade
        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);
        uint256 sharesBefore = pool.getDepositShares(alice, address(tokenA));

        // Upgrade to V2
        LendingPoolV2 implV2 = new LendingPoolV2();
        vm.prank(owner);
        pool.upgradeToAndCall(address(implV2), "");

        LendingPoolV2 poolV2 = LendingPoolV2(address(proxy));

        // State preserved
        assertEq(poolV2.getDepositShares(alice, address(tokenA)), sharesBefore);
        assertEq(poolV2.version(), "2.0.0");
        assertTrue(poolV2.newFeatureV2());
    }

    function test_Upgrade_OnlyOwner() public {
        LendingPoolV2 implV2 = new LendingPoolV2();
        vm.prank(alice);
        vm.expectRevert();
        pool.upgradeToAndCall(address(implV2), "");
    }

    // ─── Bug Fix: No Underflow After Interest Accrual ──────────────

    function test_Withdraw_NoUnderflowAfterInterest() public {
        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        vm.prank(bob);
        pool.deposit(address(tokenA), DEPOSIT);
        vm.prank(bob);
        pool.borrow(address(tokenA), 500 ether);

        vm.warp(block.timestamp + 365 days);

        uint256 aliceShares = pool.getDepositShares(alice, address(tokenA));
        uint256 aliceBalance = pool.getDepositBalance(alice, address(tokenA));
        assertGe(aliceBalance, DEPOSIT, "Alice should have earned interest");

        uint256 tokenBefore = tokenA.balanceOf(alice);
        vm.prank(alice);
        pool.withdraw(address(tokenA), aliceShares); // must not underflow
        assertGe(tokenA.balanceOf(alice) - tokenBefore, DEPOSIT, "Should receive at least principal");
    }

    function test_Repay_NoUnderflowAfterInterest() public {
        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT * 2);
        vm.prank(alice);
        pool.borrow(address(tokenA), 500 ether);

        vm.warp(block.timestamp + 365 days);

        uint256 borrowShares = pool.getBorrowShares(alice, address(tokenA));
        tokenA.mint(alice, 1000 ether);
        vm.prank(alice);
        tokenA.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        pool.repay(address(tokenA), borrowShares); // must not underflow

        assertEq(pool.getBorrowBalance(alice, address(tokenA)), 0, "Debt fully cleared");
    }

    function testFuzz_DepositWithdraw_NoUnderflow(uint256 amount, uint256 timeDelta) public {
        amount = bound(amount, 1 ether, 5000 ether);
        timeDelta = bound(timeDelta, 0, 730 days);

        tokenA.mint(alice, amount);
        vm.startPrank(alice);
        tokenA.approve(address(pool), amount);
        pool.deposit(address(tokenA), amount);
        vm.stopPrank();

        tokenA.mint(bob, amount);
        vm.startPrank(bob);
        tokenA.approve(address(pool), amount);
        pool.deposit(address(tokenA), amount);
        pool.borrow(address(tokenA), amount / 3);
        vm.stopPrank();

        vm.warp(block.timestamp + timeDelta);

        uint256 aliceShares = pool.getDepositShares(alice, address(tokenA));
        vm.prank(alice);
        pool.withdraw(address(tokenA), aliceShares);
        assertEq(pool.getDepositShares(alice, address(tokenA)), 0);
    }

    function testFuzz_BorrowRepay_FullCycleWithInterest(uint256 borrowAmt, uint256 timeDelta) public {
        uint256 liquidity = 5000 ether;
        tokenA.mint(bob, liquidity);
        vm.startPrank(bob);
        tokenA.approve(address(pool), liquidity);
        pool.deposit(address(tokenA), liquidity);
        vm.stopPrank();

        vm.prank(alice);
        pool.deposit(address(tokenA), DEPOSIT);

        borrowAmt = bound(borrowAmt, 1 ether, 700 ether); // within 75% CF on 1000 deposit
        timeDelta = bound(timeDelta, 0, 365 days);

        vm.prank(alice);
        pool.borrow(address(tokenA), borrowAmt);

        vm.warp(block.timestamp + timeDelta);

        uint256 shares = pool.getBorrowShares(alice, address(tokenA));
        uint256 owed = pool.getBorrowBalance(alice, address(tokenA));
        tokenA.mint(alice, owed); // cover interest
        vm.startPrank(alice);
        tokenA.approve(address(pool), type(uint256).max);
        pool.repay(address(tokenA), shares);
        vm.stopPrank();

        assertEq(pool.getBorrowBalance(alice, address(tokenA)), 0);
    }

    // ─── Invariants ────────────────────────────────────────────────

    // totalDeposits and totalBorrows are now stored in shares (index-scaled units).
    // The invariant still holds: borrow shares can never exceed deposit shares
    // because the liquidity check converts both to amounts before comparing.
    function invariant_TotalBorrowsNeverExceedDeposits() public view {
        address[] memory assets = pool.getSupportedAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            (,,,,, uint256 totalDeposits, uint256 totalBorrows,,,) = pool.assetConfigs(assets[i]);
            assertLe(totalBorrows, totalDeposits, "Borrow shares exceed deposit shares");
        }
    }

    function invariant_HealthFactorNeverGoesNegative() public view {
        // Health factor is always either max uint or a positive number
        uint256 hfAlice = pool.healthFactor(alice);
        uint256 hfBob   = pool.healthFactor(bob);
        // Both should be > 0 (uint256 can't go negative, but sanity check max == no debt)
        assertTrue(hfAlice > 0, "HF must be positive");
        assertTrue(hfBob > 0, "HF must be positive");
    }
}
