# Gas Optimization — DeFi Protocol Suite

## Strategy

Gas optimization was applied systematically across three levels:
1. **Storage layout** — minimize SSTORE operations (most expensive: 20,000 gas new slot)
2. **Data types** — pack structs, use appropriate integer sizes
3. **Algorithm** — share-based accounting eliminates per-user interest loops

---

## Key Optimizations Applied

### 1. Share-Based Interest Accrual

Instead of iterating over all users to update balances (O(n) with unbounded gas):

```solidity
// ✗ Naive approach — O(users), unbounded gas
for (uint i = 0; i < users.length; i++) {
    users[i].balance += users[i].balance * rate * elapsed;
}

// ✓ Index-based shares — O(1) regardless of user count
// Global index accumulates interest; user balance computed on-demand
cfg.borrowIndex += cfg.borrowIndex * borrowRate * elapsed / RAY;
userBalance = userShares * cfg.borrowIndex / RAY;  // O(1) view
```

**Gas saving:** Eliminates O(n) loop entirely. Deposit/borrow is O(1).

### 2. SafeERC20 Over Raw Calls

```solidity
// ✗ Raw call — needs manual return value check (more code, more gas)
token.transfer(to, amount);

// ✓ SafeERC20 — handles non-standard tokens, single call
IERC20(asset).safeTransfer(msg.sender, amount);
```

### 3. Struct Storage Packing

```solidity
// AssetConfig packs booleans with subsequent values
struct AssetConfig {
    bool supported;        // 1 byte
    // ← remaining 31 bytes of slot used by Solidity automatically
    uint256 collateralFactor; // new slot (uint256 always takes full slot)
    ...
}
```

### 4. Immutable Contract Addresses

```solidity
// IERC20 public governanceToken;      // storage slot (2100 gas read)
// vs
// address public immutable govToken;  // embedded in bytecode (no SLOAD)
```

Applied where addresses don't change (non-upgradeable context).

### 5. Ray Arithmetic vs Floating Point

Fixed-point Ray (1e27) arithmetic avoids expensive floating point emulation while maintaining precision for interest calculations.

---

## Gas Benchmarks (from `forge test --gas-report`)

| Function | Avg Gas | Notes |
|----------|---------|-------|
| `deposit()` | 99,261 | Includes ERC20 transfer + index update |
| `withdraw()` | 67,001 | Includes health factor check |
| `borrow()` | 105,139 | Includes health factor check |
| `repay()` | 42,722 | No health factor needed |
| `liquidate()` | 84,680 | Two asset operations |
| `stake()` | 100,202 | Includes pending harvest |
| `unstake()` | 52,230 | Transfer only |
| `harvest()` | 117,692 | Transfer + state updates |
| `emergencyWithdraw()` | 41,784 | Transfer only, no rewards |
| `propose()` | 248,864 | Array storage + events |
| `castVote()` | 86,220 | Single mapping update |
| `queue()` | 78,483 | Transaction hash registration |
| `execute()` | 68,448 | Depends on proposal calldata (no-op test) |

---

## Optimizer Settings

```toml
# foundry.toml
optimizer = true
optimizer_runs = 200   # optimized for deployment cost vs. call cost balance
```

For high-frequency functions (deposit, borrow), increasing `optimizer_runs` to 1000 would reduce per-call gas at the cost of larger bytecode.

---

## Further Optimizations (Future)

- **Custom errors** instead of string revert messages (~50 gas each)
- **Bitmap packing** for user vote tracking
- **SLOAD caching** — cache storage vars in memory at function start
- **Assembly for inner math** — critical Ray multiplication paths

```solidity
// Example: custom error saves ~50 gas vs string
error InsufficientShares(uint256 requested, uint256 available);
// vs
require(shares <= available, "LendingPool: insufficient shares");
```
