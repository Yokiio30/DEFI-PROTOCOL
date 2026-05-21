// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LiquidityMining
 * @notice Time-weighted liquidity mining rewards for LP token stakers.
 *         Supports multiple reward tokens and multiple staking pools.
 * @dev UUPS upgradeable. Storage layout is append-only.
 *
 *      Reward algorithm:
 *        accRewardPerShare += rewardRate * elapsed / totalStaked
 *        pending = userStaked * accRewardPerShare - rewardDebt
 *
 *      This is the standard Masterchef pattern adapted for multiple pools and tokens.
 */
contract LiquidityMining is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = 1e12;

    // ─────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────

    struct PoolInfo {
        IERC20 lpToken;           // staking token (LP token or asset receipt)
        uint256 allocPoint;       // relative weight for reward distribution
        uint256 lastRewardTime;   // timestamp of last reward accrual
        uint256 accRewardPerShare; // accumulated reward per share (scaled by PRECISION)
        uint256 totalStaked;      // total LP tokens staked in this pool
    }

    struct UserInfo {
        uint256 amount;       // LP tokens staked
        uint256 rewardDebt;   // reward already accounted for
        uint256 pendingReward; // harvested but not yet claimed
    }

    struct RewardToken {
        IERC20 token;
        uint256 rewardPerSecond; // tokens emitted per second across all pools
        uint256 startTime;
        uint256 endTime;
    }

    PoolInfo[] public poolInfo;
    RewardToken[] public rewardTokens;

    // poolId => user => UserInfo (per-reward-token would be a mapping of mappings in v2)
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    uint256 public totalAllocPoint;

    // ── Per-token reward tracking (append-only, UUPS-safe) ──────────────
    // poolId => rewardTokenIndex => accumulated reward per share (PRECISION-scaled)
    mapping(uint256 => mapping(uint256 => uint256)) public accRewardPerShareByToken;
    // poolId => user => rewardTokenIndex => reward debt
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public userRewardDebtByToken;
    // poolId => user => rewardTokenIndex => harvested but unclaimed reward
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public userPendingByToken;

    // ─────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────

    event PoolAdded(uint256 indexed pid, address lpToken, uint256 allocPoint);
    event PoolUpdated(uint256 indexed pid, uint256 allocPoint);
    event Staked(address indexed user, uint256 indexed pid, uint256 amount);
    event Unstaked(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvested(address indexed user, uint256 indexed pid, uint256 rewardTokenIndex, uint256 amount);
    event RewardTokenAdded(uint256 indexed index, address token, uint256 rewardPerSecond);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    // ─────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
    }

    // ─────────────────────────────────────────────
    // Admin: Pool & Reward Management
    // ─────────────────────────────────────────────

    /**
     * @notice Add a new staking pool
     * @param lpToken LP token or asset token users will stake
     * @param allocPoint Weight relative to other pools for reward sharing
     */
    function addPool(address lpToken, uint256 allocPoint) external onlyOwner {
        require(lpToken != address(0), "LiquidityMining: zero address");
        _massUpdatePools();

        totalAllocPoint += allocPoint;
        poolInfo.push(PoolInfo({
            lpToken: IERC20(lpToken),
            allocPoint: allocPoint,
            lastRewardTime: block.timestamp,
            accRewardPerShare: 0,
            totalStaked: 0
        }));

        emit PoolAdded(poolInfo.length - 1, lpToken, allocPoint);
    }

    /**
     * @notice Update allocation points for a pool
     * @param pid Pool index
     * @param allocPoint New allocation weight
     */
    function setPool(uint256 pid, uint256 allocPoint) external onlyOwner {
        _massUpdatePools();
        totalAllocPoint = totalAllocPoint - poolInfo[pid].allocPoint + allocPoint;
        poolInfo[pid].allocPoint = allocPoint;
        emit PoolUpdated(pid, allocPoint);
    }

    /**
     * @notice Add a reward token with emission schedule
     * @param token ERC-20 reward token (must be pre-funded to this contract)
     * @param rewardPerSecond Tokens emitted per second across all pools
     * @param startTime Emission start timestamp
     * @param endTime Emission end timestamp
     */
    function addRewardToken(
        address token,
        uint256 rewardPerSecond,
        uint256 startTime,
        uint256 endTime
    ) external onlyOwner {
        require(token != address(0), "LiquidityMining: zero address");
        require(startTime >= block.timestamp, "LiquidityMining: start in past");
        require(endTime > startTime, "LiquidityMining: invalid schedule");
        rewardTokens.push(RewardToken({
            token: IERC20(token),
            rewardPerSecond: rewardPerSecond,
            startTime: startTime,
            endTime: endTime
        }));
        emit RewardTokenAdded(rewardTokens.length - 1, token, rewardPerSecond);
    }

    // ─────────────────────────────────────────────
    // Core: Stake & Unstake
    // ─────────────────────────────────────────────

    /**
     * @notice Stake LP tokens into a pool to earn rewards
     * @param pid Pool index
     * @param amount Amount of LP tokens to stake
     */
    function stake(uint256 pid, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        require(amount > 0, "LiquidityMining: zero amount");
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        _updatePool(pid);

        // Accumulate pending for every reward token before changing stake
        if (user.amount > 0) {
            for (uint256 i = 0; i < rewardTokens.length; i++) {
                uint256 pending = user.amount * accRewardPerShareByToken[pid][i] / PRECISION
                    - userRewardDebtByToken[pid][msg.sender][i];
                userPendingByToken[pid][msg.sender][i] += pending;
            }
        }

        pool.lpToken.safeTransferFrom(msg.sender, address(this), amount);
        user.amount += amount;
        pool.totalStaked += amount;

        // Snapshot new debt for every reward token
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            userRewardDebtByToken[pid][msg.sender][i] =
                user.amount * accRewardPerShareByToken[pid][i] / PRECISION;
        }

        emit Staked(msg.sender, pid, amount);
    }

    /**
     * @notice Unstake LP tokens from a pool
     * @param pid Pool index
     * @param amount Amount of LP tokens to unstake
     */
    function unstake(uint256 pid, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];
        require(user.amount >= amount, "LiquidityMining: insufficient stake");

        _updatePool(pid);

        // Accumulate pending for every reward token before changing stake
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            uint256 pending = user.amount * accRewardPerShareByToken[pid][i] / PRECISION
                - userRewardDebtByToken[pid][msg.sender][i];
            userPendingByToken[pid][msg.sender][i] += pending;
        }

        user.amount -= amount;
        pool.totalStaked -= amount;

        // Snapshot new debt for every reward token
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            userRewardDebtByToken[pid][msg.sender][i] =
                user.amount * accRewardPerShareByToken[pid][i] / PRECISION;
        }

        pool.lpToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, pid, amount);
    }

    /**
     * @notice Harvest accrued rewards without changing stake
     * @param pid Pool index
     * @param rewardTokenIndex Index of reward token to harvest
     */
    function harvest(uint256 pid, uint256 rewardTokenIndex)
        external
        nonReentrant
        whenNotPaused
    {
        require(rewardTokenIndex < rewardTokens.length, "LiquidityMining: invalid reward token");
        UserInfo storage user = userInfo[pid][msg.sender];

        _updatePool(pid);

        uint256 pending = user.amount * accRewardPerShareByToken[pid][rewardTokenIndex] / PRECISION
            - userRewardDebtByToken[pid][msg.sender][rewardTokenIndex];
        uint256 totalPending = userPendingByToken[pid][msg.sender][rewardTokenIndex] + pending;

        userPendingByToken[pid][msg.sender][rewardTokenIndex] = 0;
        userRewardDebtByToken[pid][msg.sender][rewardTokenIndex] =
            user.amount * accRewardPerShareByToken[pid][rewardTokenIndex] / PRECISION;

        if (totalPending > 0) {
            RewardToken storage rt = rewardTokens[rewardTokenIndex];
            rt.token.safeTransfer(msg.sender, totalPending);
            emit Harvested(msg.sender, pid, rewardTokenIndex, totalPending);
        }
    }

    // ─────────────────────────────────────────────
    // View: Pending Rewards
    // ─────────────────────────────────────────────

    /// @notice Total pending reward across all reward tokens (display only — tokens are heterogeneous)
    function pendingReward(uint256 pid, address _user) external view returns (uint256 total) {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            total += pendingRewardByToken(pid, _user, i);
        }
    }

    /// @notice Pending reward for a specific reward token
    function pendingRewardByToken(uint256 pid, address _user, uint256 rtIdx)
        public
        view
        returns (uint256)
    {
        require(rtIdx < rewardTokens.length, "LiquidityMining: invalid reward token");
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage info = userInfo[pid][_user];

        uint256 accPerShare = accRewardPerShareByToken[pid][rtIdx];
        if (block.timestamp > pool.lastRewardTime && pool.totalStaked > 0 && totalAllocPoint > 0) {
            RewardToken storage rt = rewardTokens[rtIdx];
            if (block.timestamp >= rt.startTime && block.timestamp <= rt.endTime) {
                uint256 elapsed = block.timestamp - pool.lastRewardTime;
                uint256 poolReward = elapsed * rt.rewardPerSecond * pool.allocPoint / totalAllocPoint;
                accPerShare += poolReward * PRECISION / pool.totalStaked;
            }
        }

        return userPendingByToken[pid][_user][rtIdx]
            + info.amount * accPerShare / PRECISION
            - userRewardDebtByToken[pid][_user][rtIdx];
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function rewardTokenLength() external view returns (uint256) {
        return rewardTokens.length;
    }

    // ─────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────

    function _massUpdatePools() internal {
        for (uint256 i = 0; i < poolInfo.length; i++) {
            _updatePool(i);
        }
    }

    /**
     * @dev Accrue rewards for a single pool since lastRewardTime
     */
    function _updatePool(uint256 pid) internal {
        PoolInfo storage pool = poolInfo[pid];
        if (block.timestamp <= pool.lastRewardTime) return;

        if (pool.totalStaked == 0 || totalAllocPoint == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - pool.lastRewardTime;

        // Each reward token accrues independently into its own accRewardPerShareByToken slot
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            RewardToken storage rt = rewardTokens[i];
            if (block.timestamp < rt.startTime || block.timestamp > rt.endTime) continue;
            uint256 poolReward = elapsed * rt.rewardPerSecond * pool.allocPoint / totalAllocPoint;
            accRewardPerShareByToken[pid][i] += poolReward * PRECISION / pool.totalStaked;
        }

        pool.lastRewardTime = block.timestamp;
    }

    // ─────────────────────────────────────────────
    // Emergency
    // ─────────────────────────────────────────────

    /**
     * @notice Emergency withdraw without caring about rewards (for stuck funds)
     */
    function emergencyWithdraw(uint256 pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 amount = user.amount;

        user.amount = 0;
        user.rewardDebt = 0;
        user.pendingReward = 0;
        pool.totalStaked -= amount;

        // Clear per-token tracking so future stakes start fresh
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            userRewardDebtByToken[pid][msg.sender][i] = 0;
            userPendingByToken[pid][msg.sender][i] = 0;
        }

        pool.lpToken.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }
}
