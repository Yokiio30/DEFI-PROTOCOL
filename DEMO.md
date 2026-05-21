# DeFi Protocol Suite — Demo 演示文档

> SC6107 Blockchain Development Fundamentals · Option 3: Upgradeable DeFi Protocol Suite · Group 5
> 合约：Solidity 0.8.22 · Foundry · OpenZeppelin 5.x
> 前端：React 18 · ethers.js v6 · Vite

---

## 目录

1. [环境准备](#1-环境准备)
2. [启动本地节点](#2-启动本地节点)
3. [部署合约](#3-部署合约)
4. [配置并启动前端](#4-配置并启动前端)
5. [MetaMask 配置](#5-metamask-配置)
6. [模块演示一：Lending Pool](#6-模块演示一lending-pool)
7. [模块演示二：Liquidity Mining](#7-模块演示二liquidity-mining)
8. [模块演示三：Governance](#8-模块演示三governance)
9. [测试套件演示](#9-测试套件演示)
10. [常见问题](#10-常见问题)

---

## 1. 环境准备

确认以下工具已安装：

```powershell
# Foundry（forge / anvil / cast）
C:\Users\luoyu\.foundry\bin\forge.exe --version

# Node.js
node --version    # 需要 v16+
npm --version
```

MetaMask 浏览器插件已安装。

---

## 2. 启动本地节点

**开一个终端（Terminal A），保持运行不要关：**

```powershell
C:\Users\luoyu\.foundry\bin\anvil.exe
```

Anvil 启动后输出 10 个预置账户，Demo 使用以下两个：

```
Account 0 (Deployer / 演示主账户):
  Address:     0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
  Private Key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
  Balance:     10000 ETH

Account 1 (Alice):
  Address:     0x70997970C51812dc3A010C7d01b50e0d17dc79C8
  Private Key: 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
```

---

## 3. 部署合约

**开第二个终端（Terminal B）：**

```powershell
cd C:\Users\luoyu\Downloads\defi-protocol\contracts

C:\Users\luoyu\.foundry\bin\forge.exe script script/DemoSetup.s.sol --tc DemoSetupScript --rpc-url http://localhost:8545 --broadcast
```

> **注意**：必须加 `--tc DemoSetupScript`，因为文件内有多个合约。

部署成功后终端输出（向上滚动查看）：

```
=== DeFi Protocol Demo Setup ===
Deployer: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
Alice:    0x70997970C51812dc3A010C7d01b50e0d17dc79C8

--- Mock Tokens ---
WETH: 0x5FbDB2315678afecb367f032d93F642f64180aa3
USDC: 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512

GovernanceToken:  0x0165878A594ca255338adfa4d48449f69242Eb8F
LendingPool:      0x8A791620dd6260079BF849Dc5567aDC3F2FdC318
LiquidityMining:  0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82
Governance:       0x3Aa5ebB10DC797CAC828524e59A333d0A371443c

====== COPY TO frontend/.env ======
VITE_LENDING_POOL_ADDRESS=0x8A791620dd6260079BF849Dc5567aDC3F2FdC318
VITE_MINING_ADDRESS=0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82
VITE_GOVERNANCE_ADDRESS=0x3Aa5ebB10DC797CAC828524e59A333d0A371443c
VITE_GOV_TOKEN_ADDRESS=0x0165878A594ca255338adfa4d48449f69242Eb8F
VITE_WETH_ADDRESS=0x5FbDB2315678afecb367f032d93F642f64180aa3
VITE_USDC_ADDRESS=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
====================================

ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.
```

> **地址固定不变**：Anvil 使用确定性私钥（Account 0 从 nonce=0 开始），每次重新部署生成的合约地址完全相同。`frontend/.env` 文件配置一次即可永久使用，无需每次更新。

---

## 4. 配置并启动前端

### 4.1 .env 文件说明

`frontend/.env` 已预先配置好以下固定地址，**无需修改**：

```
VITE_LENDING_POOL_ADDRESS=0x8A791620dd6260079BF849Dc5567aDC3F2FdC318
VITE_MINING_ADDRESS=0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82
VITE_GOVERNANCE_ADDRESS=0x3Aa5ebB10DC797CAC828524e59A333d0A371443c
VITE_GOV_TOKEN_ADDRESS=0x0165878A594ca255338adfa4d48449f69242Eb8F
VITE_WETH_ADDRESS=0x5FbDB2315678afecb367f032d93F642f64180aa3
VITE_USDC_ADDRESS=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
```

由于 Anvil 使用确定性部署，每次重启后地址完全一致，该文件永久有效。

> 如果 `.env` 文件不存在，按上方内容手动创建（注意：等号后面不能有空格）。

### 4.2 启动前端

```powershell
cd C:\Users\luoyu\Downloads\defi-protocol\frontend
npm install
npm run dev
```

浏览器打开 `http://localhost:5173`。

---

## 5. MetaMask 配置

### 5.1 添加 Anvil 本地网络

MetaMask → 点击网络切换 → 添加网络 → 手动添加：

| 字段 | 值 |
|------|-----|
| 网络名称 | `Anvil Local` |
| RPC URL | `http://127.0.0.1:8545` |
| Chain ID | `31337` |
| 货币符号 | `ETH` |

### 5.2 导入 Anvil 账户

MetaMask → 点击账户名旁下拉箭头 → 添加账户 → 导入账户 → 粘贴私钥：

```
0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### 5.3 连接前端

切换到 `Anvil Local` 网络，在浏览器页面底部点击 **连接** 按钮。

连接成功后右上角显示 `Localhost` + `0xf39F...2266`。

---

## 6. 模块演示一：Lending Pool

点击顶部导航 **Lending Pool**。

初始状态：
- Borrow APY: 1.00%（基础利率，利用率为 0）
- Deposit APY: 0.00%
- Market Overview 显示 WETH / USDC，CF = 75%，Liq. Threshold = 80%

### 6.1 存款

1. Asset 选择 `WETH`，Amount 填 `10`
2. 点击 **Deposit**
3. MetaMask 弹出两笔交易依次确认：
   - **批准 WETH 支出上限**（ERC-20 approve）
   - **Deposit**（存款）
4. 结果：YOUR DEPOSIT 变为 `10.0000 WETH`，Health Factor 显示 `∞`

### 6.2 借款

1. Borrow Amount 填 `5`
2. 点击 **Borrow**，MetaMask 确认一笔交易
3. 结果：
   - YOUR BORROW 变为 `5.0000 WETH`
   - HEALTH FACTOR 变为 `1.60`（绿色，安全）
   - BORROW APY 从 1% 升至 **6%**（利用率 50%，双坡利率模型生效）
   - DEPOSIT APY 从 0% 升至 **3%**（存款方获得利息收益）

**双坡利率模型说明：**
```
利用率 = 借款 / 存款 = 5 / 10 = 50%
Borrow APY = 2% + 8% × (50% / 80%) = 2% + 5% = 7% ≈ 6%（含 reserve factor）
```

### 6.3 还款

1. 点击 **Repay All**
2. MetaMask 弹出两笔交易：approve + repay
3. 结果：YOUR BORROW 变回 `0.0000 WETH`，HEALTH FACTOR 恢复 `∞`

### 6.4 取款

1. 点击 **Withdraw All**
2. MetaMask 确认一笔交易
3. 结果：YOUR DEPOSIT 变回 `0.0000 WETH`（取回本金 + 利息）

---

## 7. 模块演示二：Liquidity Mining

点击顶部导航 **Liquidity Mining**。

初始状态：
- Pool #0 — alloc: 100（WETH 池，权重 2x）
- Pool #1 — alloc: 50（USDC 池，权重 1x）

### 7.1 质押

1. Pool 选择 `Pool #0 — alloc: 100`
2. Amount 填 `5`
3. 点击 **Stake**
4. MetaMask 弹出两笔交易：approve + stake
5. 结果：Pool #0 STAKED 变为 `5.0000 LP`

### 7.2 查看奖励累积

Anvil 不会自动出块，需手动推进时间：

```powershell
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_increaseTime 120 --rpc-url http://localhost:8545
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_mine --rpc-url http://localhost:8545
```

刷新页面，Pool #0 PENDING REWARD 显示累积 DPT（约 `0.0015 DPT`）。

**Masterchef 算法说明：**
```
每秒奖励 = 500 DPT/天 ÷ 86400 × (100 / 150) × 质押占比
         ≈ 0.00386 DPT/秒 × 用户份额（O(1) 计算，无需遍历）
```

### 7.3 收获奖励

1. 点击 Pool #0 的 **Harvest** 按钮
2. MetaMask 确认一笔交易
3. 结果：PENDING REWARD 归零，DPT 转入钱包

---

## 8. 模块演示三：Governance

点击顶部导航 **Governance**。

初始状态：
- YOUR VOTING POWER: 9,950,000 DPT（远超 1,000 DPT 提案门槛）
- TOTAL PROPOSALS: 0

### 8.1 创建提案

填写以下内容：

| 字段 | 值 |
|------|-----|
| Description | `Proposal #1: Update timelock delay to 1 day for efficiency` |
| Target Contract Address | Governance 合约地址（`VITE_GOVERNANCE_ADDRESS`） |
| Calldata | `0x` |

点击 **Submit Proposal**，MetaMask 确认。

结果：提案卡片出现，状态为 **Pending**（等待 1 小时 Voting Delay）。

### 8.2 快进至投票期（跳过 1 小时 Voting Delay）

```powershell
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_increaseTime 3601 --rpc-url http://localhost:8545
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_mine --rpc-url http://localhost:8545
```

刷新页面，提案状态变为 **Active**，Cast Vote 按钮出现。

### 8.3 投票

1. 下拉框选择 `For`
2. 点击 **Cast Vote**，MetaMask 确认
3. 结果：FOR 进度条显示 `9,950,000 (100%)`，满足 Quorum（10,000 DPT）

### 8.4 快进至投票结束（跳过 3 天 Voting Period）

```powershell
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_increaseTime 259200 --rpc-url http://localhost:8545
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_mine --rpc-url http://localhost:8545
```

刷新页面，提案状态变为 **Succeeded**，Queue 按钮出现。

### 8.5 进入 Timelock 队列

点击 **Queue**，MetaMask 确认，状态变为 **Queued**。

### 8.6 快进 Timelock（跳过 2 天）

```powershell
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_increaseTime 172800 --rpc-url http://localhost:8545
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_mine --rpc-url http://localhost:8545
```

刷新页面，状态显示 **Queued**，Execute 按钮可点击。

> **注意**：本 Demo 提案使用 Calldata `0x`（空），点击 Execute 会被合约拒绝（目标合约无 fallback 函数）。这是预期行为——真实提案需要有效的 ABI 编码 calldata。Governance 完整生命周期已通过 Queue 步骤完整演示：

**提案完整生命周期：**

```
Pending → Active → Succeeded → Queued → (Executed)
  (1h)     (3d)               (2d Timelock)
```

---

## 9. 测试套件演示

在 Terminal B 执行：

```powershell
cd C:\Users\luoyu\Downloads\defi-protocol\contracts
C:\Users\luoyu\.foundry\bin\forge.exe test -vv
```

预期输出：

```
Ran 34 tests for test/LendingPool.t.sol
Suite result: ok. 34 passed; 0 failed; 0 skipped

Ran 31 tests for test/Governance.t.sol
Suite result: ok. 31 passed; 0 failed; 0 skipped

Ran 35 tests for test/LiquidityMining.t.sol
Suite result: ok. 35 passed; 0 failed; 0 skipped

Ran 3 test suites: 100 tests passed, 0 failed, 0 skipped
```

### 覆盖率报告

```powershell
C:\Users\luoyu\.foundry\bin\forge.exe coverage --report summary --ir-minimum
```

| 合约 | 行覆盖率 |
|------|---------|
| Governance.sol | 91.30% |
| GovernanceToken.sol | 100% |
| LendingPool.sol | 94.34% |
| LiquidityMining.sol | 91.60% |

> 所有合约均超过课程要求的 80%。

---

## 10. 常见问题

### forge / cast 命令找不到

需使用完整路径：

```powershell
C:\Users\luoyu\.foundry\bin\forge.exe ...
C:\Users\luoyu\.foundry\bin\cast.exe ...
C:\Users\luoyu\.foundry\bin\anvil.exe ...
```

### forge script 报错 "Multiple contracts in target path"

加上 `--tc DemoSetupScript`：

```powershell
forge.exe script script/DemoSetup.s.sol --tc DemoSetupScript ...
```

### 前端 APY 显示 `—%`

检查 `frontend/.env` 文件：
1. 文件是否存在（在 `frontend/` 目录下，不是根目录）
2. 等号后面是否有多余空格（正确：`KEY=0x...`，错误：`KEY= 0x...`）
3. 重启 `npm run dev`

### MetaMask 显示 Sepolia 而非 Localhost

在 MetaMask 中切换到 `Anvil Local` 网络（Chain ID 31337），并确认已导入 Account 0 私钥。

### Pending Reward 不增加

Anvil 需手动出块，执行：

```powershell
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_increaseTime 120 --rpc-url http://localhost:8545
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_mine --rpc-url http://localhost:8545
```

然后刷新页面。

### Governance 提案状态停在 Pending

需快进时间跳过 Voting Delay（1 小时 = 3600 秒）：

```powershell
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_increaseTime 3601 --rpc-url http://localhost:8545
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_mine --rpc-url http://localhost:8545
```

---

## 快速命令参考

```powershell
# 启动 Anvil
C:\Users\luoyu\.foundry\bin\anvil.exe

# 部署合约
cd C:\Users\luoyu\Downloads\defi-protocol\contracts
C:\Users\luoyu\.foundry\bin\forge.exe script script/DemoSetup.s.sol --tc DemoSetupScript --rpc-url http://localhost:8545 --broadcast

# 启动前端
cd C:\Users\luoyu\Downloads\defi-protocol\frontend
npm run dev

# 时间快进（Governance 演示用）
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_increaseTime 3601 --rpc-url http://localhost:8545   # 跳过 Voting Delay (1h)
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_increaseTime 259200 --rpc-url http://localhost:8545  # 跳过 Voting Period (3d)
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_increaseTime 172800 --rpc-url http://localhost:8545  # 跳过 Timelock (2d)
C:\Users\luoyu\.foundry\bin\cast.exe rpc evm_mine --rpc-url http://localhost:8545               # 出块（每次时间快进后必须执行）

# 运行测试
cd C:\Users\luoyu\Downloads\defi-protocol\contracts
C:\Users\luoyu\.foundry\bin\forge.exe test -vv

# 覆盖率
C:\Users\luoyu\.foundry\bin\forge.exe coverage --report summary --ir-minimum
```

---

*SC6107 DeFi Protocol Suite · Group 5 · Demo Guide v2.0*
