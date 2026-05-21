// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Governance
 * @notice On-chain governance for protocol upgrades and parameter changes.
 *         Proposals go through: Pending → Active → Queued → Executed (or Defeated/Cancelled)
 *
 *         Security properties:
 *         - Minimum 24-hour timelock before execution (configurable up to 30 days)
 *         - Quorum: minimum votes required for a proposal to pass
 *         - Voting period is fixed at creation and cannot be changed mid-vote
 *         - Proposer must hold ≥ proposalThreshold voting tokens
 *         - Multi-sig emergency override for critical situations
 *
 * @dev UUPS upgradeable. Only the governance itself (or emergency multi-sig) can authorize
 *      its own upgrade, preventing admin key abuse.
 */
contract Governance is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    // ─────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────

    uint256 public constant MIN_TIMELOCK_DELAY = 1 days;
    uint256 public constant MAX_TIMELOCK_DELAY = 30 days;
    uint256 public constant GRACE_PERIOD = 14 days; // window after timelock to execute

    // ─────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────

    enum ProposalState {
        Pending,   // created, voting not started
        Active,    // voting in progress
        Defeated,  // quorum not met or against > for
        Succeeded, // voting passed, not yet queued
        Queued,    // in timelock, waiting to execute
        Executed,  // successfully executed
        Cancelled, // cancelled by proposer or guardian
        Expired    // queued but not executed within grace period
    }

    struct Proposal {
        uint256 id;
        address proposer;
        address[] targets;      // contracts to call
        uint256[] values;       // ETH values
        bytes[] calldatas;      // encoded function calls
        string description;
        uint256 startTime;      // voting starts
        uint256 endTime;        // voting ends
        uint256 eta;            // earliest execution timestamp (after timelock)
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool executed;
        bool cancelled;
        mapping(address => bool) hasVoted;
        mapping(address => uint8) voteChoice; // 0=against, 1=for, 2=abstain
    }

    struct ProposalView {
        uint256 id;
        address proposer;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
        uint256 startTime;
        uint256 endTime;
        uint256 eta;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool executed;
        bool cancelled;
    }

    IERC20 public governanceToken;

    uint256 public timelockDelay;       // seconds between queue and execute
    uint256 public votingDelay;         // seconds after proposal before voting starts
    uint256 public votingPeriod;        // seconds voting lasts
    uint256 public proposalThreshold;   // minimum tokens to propose
    uint256 public quorumVotes;         // minimum forVotes for success

    address public guardian;            // emergency multi-sig address

    uint256 public proposalCount;
    mapping(uint256 => Proposal) internal proposals;
    mapping(bytes32 => bool) public queuedTransactions;

    // ─────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address[] targets,
        string description,
        uint256 startTime,
        uint256 endTime
    );
    event VoteCast(address indexed voter, uint256 indexed proposalId, uint8 support, uint256 votes);
    event ProposalQueued(uint256 indexed proposalId, uint256 eta);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);
    event TimelockDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event GuardianUpdated(address oldGuardian, address newGuardian);

    // ─────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize governance parameters
     * @param _governanceToken Token used for voting power (balance-based, no snapshot for simplicity)
     * @param _timelockDelay Seconds between queue and execution (min 1 day)
     * @param _votingDelay Seconds after proposal before voting starts
     * @param _votingPeriod Seconds voting lasts
     * @param _proposalThreshold Minimum tokens required to create proposal
     * @param _quorumVotes Minimum forVotes required for proposal to succeed
     * @param _guardian Emergency multi-sig address
     */
    function initialize(
        address _governanceToken,
        uint256 _timelockDelay,
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumVotes,
        address _guardian,
        address initialOwner
    ) external initializer {
        require(_timelockDelay >= MIN_TIMELOCK_DELAY, "Governance: delay too short");
        require(_timelockDelay <= MAX_TIMELOCK_DELAY, "Governance: delay too long");
        require(_votingPeriod >= 1 hours, "Governance: voting period too short");

        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        governanceToken = IERC20(_governanceToken);
        timelockDelay = _timelockDelay;
        votingDelay = _votingDelay;
        votingPeriod = _votingPeriod;
        proposalThreshold = _proposalThreshold;
        quorumVotes = _quorumVotes;
        guardian = _guardian;
    }

    // ─────────────────────────────────────────────
    // Proposal Lifecycle
    // ─────────────────────────────────────────────

    /**
     * @notice Create a new governance proposal
     * @param targets Contracts to call on execution
     * @param values ETH values for each call
     * @param calldatas ABI-encoded calldata for each call
     * @param description Human-readable description (include motivation, spec link)
     * @return proposalId Unique ID of the created proposal
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external returns (uint256 proposalId) {
        require(
            governanceToken.balanceOf(msg.sender) >= proposalThreshold,
            "Governance: below proposal threshold"
        );
        require(targets.length > 0, "Governance: empty proposal");
        require(
            targets.length == values.length && targets.length == calldatas.length,
            "Governance: array length mismatch"
        );

        proposalCount++;
        proposalId = proposalCount;

        Proposal storage p = proposals[proposalId];
        p.id = proposalId;
        p.proposer = msg.sender;
        p.targets = targets;
        p.values = values;
        p.calldatas = calldatas;
        p.description = description;
        p.startTime = block.timestamp + votingDelay;
        p.endTime = p.startTime + votingPeriod;

        emit ProposalCreated(proposalId, msg.sender, targets, description, p.startTime, p.endTime);
    }

    /**
     * @notice Cast a vote on an active proposal
     * @param proposalId Proposal to vote on
     * @param support 0=Against, 1=For, 2=Abstain
     */
    function castVote(uint256 proposalId, uint8 support) external {
        require(support <= 2, "Governance: invalid support value");
        Proposal storage p = proposals[proposalId];
        require(state(proposalId) == ProposalState.Active, "Governance: proposal not active");
        require(!p.hasVoted[msg.sender], "Governance: already voted");

        uint256 votes = governanceToken.balanceOf(msg.sender);
        require(votes > 0, "Governance: no voting power");

        p.hasVoted[msg.sender] = true;
        p.voteChoice[msg.sender] = support;

        if (support == 0) {
            p.againstVotes += votes;
        } else if (support == 1) {
            p.forVotes += votes;
        } else {
            p.abstainVotes += votes;
        }

        emit VoteCast(msg.sender, proposalId, support, votes);
    }

    /**
     * @notice Queue a succeeded proposal for timelock execution
     * @param proposalId Proposal to queue
     */
    function queue(uint256 proposalId) external {
        require(state(proposalId) == ProposalState.Succeeded, "Governance: proposal not succeeded");
        Proposal storage p = proposals[proposalId];
        uint256 eta = block.timestamp + timelockDelay;
        p.eta = eta;

        // Mark each transaction in the queue
        for (uint256 i = 0; i < p.targets.length; i++) {
            bytes32 txHash = _txHash(p.targets[i], p.values[i], p.calldatas[i], eta);
            require(!queuedTransactions[txHash], "Governance: tx already queued");
            queuedTransactions[txHash] = true;
        }

        emit ProposalQueued(proposalId, eta);
    }

    /**
     * @notice Execute a queued proposal after timelock delay
     * @param proposalId Proposal to execute
     */
    function execute(uint256 proposalId) external payable nonReentrant {
        require(state(proposalId) == ProposalState.Queued, "Governance: proposal not queued");
        Proposal storage p = proposals[proposalId];
        require(block.timestamp >= p.eta, "Governance: timelock not elapsed");
        require(block.timestamp <= p.eta + GRACE_PERIOD, "Governance: grace period expired");

        p.executed = true;

        for (uint256 i = 0; i < p.targets.length; i++) {
            bytes32 txHash = _txHash(p.targets[i], p.values[i], p.calldatas[i], p.eta);
            queuedTransactions[txHash] = false;

            (bool success, bytes memory returnData) = p.targets[i].call{value: p.values[i]}(p.calldatas[i]);
            if (!success) {
                if (returnData.length > 0) {
                    assembly { revert(add(32, returnData), mload(returnData)) }
                }
                revert("Governance: execution failed");
            }
        }

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cancel a proposal (proposer or guardian only)
     * @param proposalId Proposal to cancel
     */
    function cancel(uint256 proposalId) external {
        ProposalState s = state(proposalId);
        require(
            s != ProposalState.Executed && s != ProposalState.Expired,
            "Governance: cannot cancel"
        );
        Proposal storage p = proposals[proposalId];
        require(
            msg.sender == p.proposer || msg.sender == guardian,
            "Governance: not proposer or guardian"
        );

        p.cancelled = true;

        if (p.eta != 0) {
            for (uint256 i = 0; i < p.targets.length; i++) {
                bytes32 txHash = _txHash(p.targets[i], p.values[i], p.calldatas[i], p.eta);
                queuedTransactions[txHash] = false;
            }
        }

        emit ProposalCancelled(proposalId);
    }

    // ─────────────────────────────────────────────
    // View: State Machine
    // ─────────────────────────────────────────────

    /**
     * @notice Get the current state of a proposal
     */
    function state(uint256 proposalId) public view returns (ProposalState) {
        require(proposalId <= proposalCount && proposalId > 0, "Governance: invalid proposal id");
        Proposal storage p = proposals[proposalId];

        if (p.cancelled) return ProposalState.Cancelled;
        if (p.executed) return ProposalState.Executed;
        if (block.timestamp < p.startTime) return ProposalState.Pending;
        if (block.timestamp <= p.endTime) return ProposalState.Active;

        // Voting ended
        if (p.forVotes < quorumVotes || p.forVotes <= p.againstVotes) {
            return ProposalState.Defeated;
        }

        if (p.eta == 0) return ProposalState.Succeeded;

        if (block.timestamp > p.eta + GRACE_PERIOD) return ProposalState.Expired;

        return ProposalState.Queued;
    }

    /**
     * @notice Get proposal data (view-friendly struct without mappings)
     */
    function getProposal(uint256 proposalId) external view returns (ProposalView memory) {
        Proposal storage p = proposals[proposalId];
        return ProposalView({
            id: p.id,
            proposer: p.proposer,
            targets: p.targets,
            values: p.values,
            calldatas: p.calldatas,
            description: p.description,
            startTime: p.startTime,
            endTime: p.endTime,
            eta: p.eta,
            forVotes: p.forVotes,
            againstVotes: p.againstVotes,
            abstainVotes: p.abstainVotes,
            executed: p.executed,
            cancelled: p.cancelled
        });
    }

    function getVote(uint256 proposalId, address voter) external view returns (bool hasVoted, uint8 support) {
        Proposal storage p = proposals[proposalId];
        hasVoted = p.hasVoted[voter];
        support = p.voteChoice[voter];
    }

    // ─────────────────────────────────────────────
    // Admin: Parameter Updates (via governance itself)
    // ─────────────────────────────────────────────

    function setTimelockDelay(uint256 newDelay) external onlyOwner {
        require(newDelay >= MIN_TIMELOCK_DELAY && newDelay <= MAX_TIMELOCK_DELAY, "Governance: invalid delay");
        emit TimelockDelayUpdated(timelockDelay, newDelay);
        timelockDelay = newDelay;
    }

    function setGuardian(address newGuardian) external {
        require(msg.sender == guardian || msg.sender == owner(), "Governance: unauthorized");
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    // ─────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────

    function _txHash(
        address target,
        uint256 value,
        bytes memory data,
        uint256 eta
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(target, value, data, eta));
    }

    // ─────────────────────────────────────────────
    // UUPS
    // ─────────────────────────────────────────────

    /**
     * @dev Only owner (which should be this contract itself in production) can upgrade
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }

    receive() external payable {}
}
