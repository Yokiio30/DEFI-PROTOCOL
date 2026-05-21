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
 * @title LendingPool
 * @notice Upgradeable lending pool supporting multi-asset deposits, collateralized borrowing,
 *         and automated liquidations. Implements utilization-based interest rate model.
 * @dev Uses UUPS proxy pattern. Storage layout must remain compatible across upgrades.
 *      All state variables declared here must never be removed or reordered in future versions.
 */
contract LendingPool is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────
    // Storage (never reorder or remove for upgrade safety)
    // ─────────────────────────────────────────────

    struct AssetConfig {
        bool supported;
        uint256 collateralFactor; // basis points, e.g. 7500 = 75%
        uint256 liquidationThreshold; // basis points, e.g. 8000 = 80%
        uint256 liquidationPenalty;   // basis points, e.g. 500  = 5%
        uint256 reserveFactor;        // basis points, portion of interest to protocol
        // Stored in shares (scaled by index), NOT raw token amounts.
        // Actual amounts = totalDeposits * depositIndex / RAY
        uint256 totalDeposits;
        uint256 totalBorrows;
        uint256 lastUpdateTimestamp;
        uint256 borrowIndex;          // Ray (1e27) scaled cumulative borrow index
        uint256 depositIndex;         // Ray scaled cumulative deposit index
    }

    struct UserAccount {
        mapping(address => uint256) depositShares;   // asset => scaled shares
        mapping(address => uint256) borrowShares;    // asset => scaled shares
    }

    // Base rate: 2% APR (per second in Ray)
    uint256 public constant BASE_RATE = 634195839675291730;
    // Slope1: 0→optimal utilization, reaches +8% APR at kink
    uint256 public constant SLOPE1    = 2536783358701166920;
    // Slope2: beyond optimal, steep increase
    uint256 public constant SLOPE2    = 79274479959411466260;
    uint256 public constant OPTIMAL_UTILIZATION = 8e26;  // 80% in Ray
    uint256 public constant RAY = 1e27;
    uint256 public constant HEALTH_FACTOR_LIQUIDATION = 1e18; // 1.0

    mapping(address => AssetConfig) public assetConfigs;
    mapping(address => UserAccount) internal _accounts;
    address[] public supportedAssets;

    mapping(address => uint256) public protocolReserves; // asset => reserve amount

    // ─────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────

    event AssetAdded(address indexed asset, uint256 collateralFactor, uint256 liquidationThreshold);
    event Deposited(address indexed user, address indexed asset, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, address indexed asset, uint256 amount, uint256 shares);
    event Borrowed(address indexed user, address indexed asset, uint256 amount, uint256 shares);
    event Repaid(address indexed user, address indexed asset, uint256 amount, uint256 shares);
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        address indexed collateralAsset,
        address debtAsset,
        uint256 debtRepaid,
        uint256 collateralSeized
    );
    event IndexUpdated(address indexed asset, uint256 borrowIndex, uint256 depositIndex);

    // ─────────────────────────────────────────────
    // Initializer (replaces constructor for upgradeable contracts)
    // ─────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the lending pool (called once via proxy)
     * @param initialOwner Address that will own the contract and control upgrades via governance
     */
    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
    }

    // ─────────────────────────────────────────────
    // Admin: Asset Management
    // ─────────────────────────────────────────────

    /**
     * @notice Add a supported collateral/borrow asset
     * @param asset ERC-20 token address
     * @param collateralFactor Max LTV in basis points (e.g. 7500 = 75%)
     * @param liquidationThreshold Threshold before liquidation allowed (e.g. 8000)
     * @param liquidationPenalty Bonus for liquidators in basis points (e.g. 500)
     * @param reserveFactor Protocol fee share in basis points (e.g. 1000 = 10%)
     */
    function addAsset(
        address asset,
        uint256 collateralFactor,
        uint256 liquidationThreshold,
        uint256 liquidationPenalty,
        uint256 reserveFactor
    ) external onlyOwner {
        require(asset != address(0), "LendingPool: zero address");
        require(!assetConfigs[asset].supported, "LendingPool: already supported");
        require(collateralFactor < liquidationThreshold, "LendingPool: CF >= LT");
        require(liquidationThreshold <= 10000, "LendingPool: LT > 100%");

        assetConfigs[asset] = AssetConfig({
            supported: true,
            collateralFactor: collateralFactor,
            liquidationThreshold: liquidationThreshold,
            liquidationPenalty: liquidationPenalty,
            reserveFactor: reserveFactor,
            totalDeposits: 0,
            totalBorrows: 0,
            lastUpdateTimestamp: block.timestamp,
            borrowIndex: RAY,
            depositIndex: RAY
        });
        supportedAssets.push(asset);

        emit AssetAdded(asset, collateralFactor, liquidationThreshold);
    }

    // ─────────────────────────────────────────────
    // Core: Deposit
    // ─────────────────────────────────────────────

    /**
     * @notice Deposit tokens to earn interest
     * @param asset Token to deposit
     * @param amount Amount to deposit (in token decimals)
     */
    function deposit(address asset, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        require(assetConfigs[asset].supported, "LendingPool: unsupported asset");
        require(amount > 0, "LendingPool: zero amount");

        _updateIndexes(asset);

        uint256 shares = _toDepositShares(asset, amount);
        _accounts[msg.sender].depositShares[asset] += shares;
        assetConfigs[asset].totalDeposits += shares; // stored in shares, not raw amount

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, asset, amount, shares);
    }

    /**
     * @notice Withdraw previously deposited tokens + accrued interest
     * @param asset Token to withdraw
     * @param shares Amount of deposit shares to burn
     */
    function withdraw(address asset, uint256 shares)
        external
        nonReentrant
        whenNotPaused
    {
        require(shares > 0, "LendingPool: zero shares");
        UserAccount storage account = _accounts[msg.sender];
        require(account.depositShares[asset] >= shares, "LendingPool: insufficient shares");

        _updateIndexes(asset);

        uint256 amount = _fromDepositShares(asset, shares);
        account.depositShares[asset] -= shares;
        assetConfigs[asset].totalDeposits -= shares; // mirror deposit: subtract shares

        _requireHealthy(msg.sender);

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, asset, amount, shares);
    }

    // ─────────────────────────────────────────────
    // Core: Borrow & Repay
    // ─────────────────────────────────────────────

    /**
     * @notice Borrow tokens against deposited collateral
     * @param asset Token to borrow
     * @param amount Amount to borrow
     */
    function borrow(address asset, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        require(assetConfigs[asset].supported, "LendingPool: unsupported asset");
        require(amount > 0, "LendingPool: zero amount");

        AssetConfig storage cfg = assetConfigs[asset];

        _updateIndexes(asset);

        // Convert share-based totals to actual token amounts for liquidity check
        uint256 totalDepositAmt = cfg.totalDeposits * cfg.depositIndex / RAY;
        uint256 totalBorrowAmt  = cfg.totalBorrows  * cfg.borrowIndex  / RAY;
        uint256 available = totalDepositAmt > totalBorrowAmt ? totalDepositAmt - totalBorrowAmt : 0;
        require(amount <= available, "LendingPool: insufficient liquidity");

        uint256 shares = _toBorrowShares(asset, amount);
        _accounts[msg.sender].borrowShares[asset] += shares;
        cfg.totalBorrows += shares; // stored in shares, not raw amount

        _requireHealthy(msg.sender);

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, asset, amount, shares);
    }

    /**
     * @notice Repay borrowed tokens
     * @param asset Token to repay
     * @param shares Borrow shares to repay (use type(uint256).max to repay all)
     */
    function repay(address asset, uint256 shares)
        external
        nonReentrant
        whenNotPaused
    {
        UserAccount storage account = _accounts[msg.sender];
        uint256 userShares = account.borrowShares[asset];
        require(userShares > 0, "LendingPool: no debt");

        _updateIndexes(asset);

        if (shares > userShares) shares = userShares;

        uint256 amount = _fromBorrowShares(asset, shares);
        account.borrowShares[asset] -= shares;
        assetConfigs[asset].totalBorrows -= shares; // mirror borrow: subtract shares

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        emit Repaid(msg.sender, asset, amount, shares);
    }

    // ─────────────────────────────────────────────
    // Core: Liquidation
    // ─────────────────────────────────────────────

    /**
     * @notice Liquidate an undercollateralized position
     * @dev Liquidator repays debtAsset debt and receives collateralAsset + penalty bonus
     * @param borrower Address of the undercollateralized user
     * @param debtAsset Asset whose debt will be repaid
     * @param collateralAsset Asset to seize as repayment + bonus
     * @param debtShares Amount of debt shares to repay
     */
    function liquidate(
        address borrower,
        address debtAsset,
        address collateralAsset,
        uint256 debtShares
    ) external nonReentrant whenNotPaused {
        require(healthFactor(borrower) < HEALTH_FACTOR_LIQUIDATION, "LendingPool: healthy position");

        _updateIndexes(debtAsset);
        _updateIndexes(collateralAsset);

        UserAccount storage account = _accounts[borrower];
        uint256 userDebtShares = account.borrowShares[debtAsset];
        // Max 50% of debt per liquidation
        uint256 maxShares = userDebtShares / 2;
        if (debtShares > maxShares) debtShares = maxShares;

        uint256 debtAmount = _fromBorrowShares(debtAsset, debtShares);

        // Calculate collateral to seize including liquidation penalty
        AssetConfig storage collCfg = assetConfigs[collateralAsset];
        uint256 penalty = collCfg.liquidationPenalty;
        uint256 collateralAmount = debtAmount * (10000 + penalty) / 10000;

        uint256 collateralShares = _toDepositShares(collateralAsset, collateralAmount);
        require(account.depositShares[collateralAsset] >= collateralShares, "LendingPool: insufficient collateral");

        // Update state (track totals in shares, matching deposit/borrow logic)
        account.borrowShares[debtAsset] -= debtShares;
        account.depositShares[collateralAsset] -= collateralShares;
        assetConfigs[debtAsset].totalBorrows -= debtShares;
        assetConfigs[collateralAsset].totalDeposits -= collateralShares;

        // Transfer: liquidator pays debt, receives collateral
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), debtAmount);
        IERC20(collateralAsset).safeTransfer(msg.sender, collateralAmount);

        emit Liquidated(msg.sender, borrower, collateralAsset, debtAsset, debtAmount, collateralAmount);
    }

    // ─────────────────────────────────────────────
    // Interest Rate Model
    // ─────────────────────────────────────────────

    /**
     * @notice Compute per-second borrow rate using two-slope model
     * @param asset Token to compute rate for
     * @return rate Per-second borrow rate in Ray (1e27)
     */
    function getBorrowRate(address asset) public view returns (uint256 rate) {
        AssetConfig storage cfg = assetConfigs[asset];
        if (cfg.totalDeposits == 0) return BASE_RATE;

        // totalDeposits/totalBorrows are stored in shares; convert to amounts for utilization
        uint256 totalDepositAmt = cfg.totalDeposits * cfg.depositIndex / RAY;
        uint256 totalBorrowAmt  = cfg.totalBorrows  * cfg.borrowIndex  / RAY;
        if (totalDepositAmt == 0) return BASE_RATE;

        uint256 utilization = totalBorrowAmt * RAY / totalDepositAmt;

        if (utilization <= OPTIMAL_UTILIZATION) {
            rate = BASE_RATE + (SLOPE1 * utilization / OPTIMAL_UTILIZATION);
        } else {
            uint256 excessUtil = utilization - OPTIMAL_UTILIZATION;
            uint256 maxExcess = RAY - OPTIMAL_UTILIZATION;
            rate = BASE_RATE + SLOPE1 + (SLOPE2 * excessUtil / maxExcess);
        }
    }

    /**
     * @notice Compute per-second deposit rate (borrow rate * utilization * (1 - reserve factor))
     */
    function getDepositRate(address asset) public view returns (uint256) {
        AssetConfig storage cfg = assetConfigs[asset];
        if (cfg.totalDeposits == 0) return 0;
        uint256 totalDepositAmt = cfg.totalDeposits * cfg.depositIndex / RAY;
        uint256 totalBorrowAmt  = cfg.totalBorrows  * cfg.borrowIndex  / RAY;
        if (totalDepositAmt == 0) return 0;
        uint256 util = totalBorrowAmt * RAY / totalDepositAmt;
        uint256 borrowRate = getBorrowRate(asset);
        uint256 grossDepositRate = borrowRate * util / RAY;
        return grossDepositRate * (10000 - cfg.reserveFactor) / 10000;
    }

    // ─────────────────────────────────────────────
    // Health Factor
    // ─────────────────────────────────────────────

    /**
     * @notice Compute health factor for a user (1e18 = 1.0; below 1.0 = liquidatable)
     * @dev Simplified: assumes all assets have price = 1 (integrate oracle in production)
     */
    function healthFactor(address user) public view returns (uint256) {
        uint256 totalCollateralValue = 0;
        uint256 totalDebtValue = 0;

        for (uint256 i = 0; i < supportedAssets.length; i++) {
            address asset = supportedAssets[i];
            AssetConfig storage cfg = assetConfigs[asset];
            UserAccount storage account = _accounts[user];

            uint256 depositAmt = _fromDepositShares(asset, account.depositShares[asset]);
            uint256 borrowAmt  = _fromBorrowShares(asset, account.borrowShares[asset]);

            totalCollateralValue += depositAmt * cfg.liquidationThreshold / 10000;
            totalDebtValue += borrowAmt;
        }

        if (totalDebtValue == 0) return type(uint256).max;
        return totalCollateralValue * 1e18 / totalDebtValue;
    }

    // ─────────────────────────────────────────────
    // View: User Balances
    // ─────────────────────────────────────────────

    function getDepositBalance(address user, address asset) external view returns (uint256) {
        return _fromDepositShares(asset, _accounts[user].depositShares[asset]);
    }

    function getBorrowBalance(address user, address asset) external view returns (uint256) {
        return _fromBorrowShares(asset, _accounts[user].borrowShares[asset]);
    }

    function getDepositShares(address user, address asset) external view returns (uint256) {
        return _accounts[user].depositShares[asset];
    }

    function getBorrowShares(address user, address asset) external view returns (uint256) {
        return _accounts[user].borrowShares[asset];
    }

    function getSupportedAssets() external view returns (address[] memory) {
        return supportedAssets;
    }

    // ─────────────────────────────────────────────
    // Internal: Index Accrual
    // ─────────────────────────────────────────────

    /**
     * @dev Accrue interest since lastUpdateTimestamp and update both indexes
     *      borrowIndex grows at borrowRate; depositIndex grows at depositRate
     *      Uses simple linear approximation (compound approximation for production)
     */
    function _updateIndexes(address asset) internal {
        AssetConfig storage cfg = assetConfigs[asset];
        uint256 elapsed = block.timestamp - cfg.lastUpdateTimestamp;
        if (elapsed == 0) return;

        uint256 borrowRate = getBorrowRate(asset);
        uint256 depositRate = getDepositRate(asset);

        cfg.borrowIndex  = cfg.borrowIndex  + (cfg.borrowIndex  * borrowRate  * elapsed / RAY);
        cfg.depositIndex = cfg.depositIndex + (cfg.depositIndex * depositRate * elapsed / RAY);
        cfg.lastUpdateTimestamp = block.timestamp;

        emit IndexUpdated(asset, cfg.borrowIndex, cfg.depositIndex);
    }

    // ─────────────────────────────────────────────
    // Internal: Share Conversion
    // ─────────────────────────────────────────────

    function _toDepositShares(address asset, uint256 amount) internal view returns (uint256) {
        uint256 index = assetConfigs[asset].depositIndex;
        return amount * RAY / index;
    }

    function _fromDepositShares(address asset, uint256 shares) internal view returns (uint256) {
        uint256 index = assetConfigs[asset].depositIndex;
        return shares * index / RAY;
    }

    function _toBorrowShares(address asset, uint256 amount) internal view returns (uint256) {
        uint256 index = assetConfigs[asset].borrowIndex;
        return amount * RAY / index;
    }

    function _fromBorrowShares(address asset, uint256 shares) internal view returns (uint256) {
        uint256 index = assetConfigs[asset].borrowIndex;
        return shares * index / RAY;
    }

    // ─────────────────────────────────────────────
    // Internal: Validation
    // ─────────────────────────────────────────────

    function _requireHealthy(address user) internal view {
        uint256 hf = healthFactor(user);
        require(hf >= HEALTH_FACTOR_LIQUIDATION, "LendingPool: undercollateralized");
    }

    // ─────────────────────────────────────────────
    // Emergency Controls
    // ─────────────────────────────────────────────

    /// @notice Pause all user-facing functions (emergency only)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause
    function unpause() external onlyOwner {
        _unpause();
    }

    // ─────────────────────────────────────────────
    // UUPS: Upgrade Authorization
    // ─────────────────────────────────────────────

    /**
     * @dev Only owner (governance timelock) can authorize upgrades
     *      In production: replace onlyOwner with governance proposal check
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Returns current implementation version
     */
    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }
}
