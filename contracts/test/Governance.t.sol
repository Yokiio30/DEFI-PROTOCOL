// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/Governance.sol";
import "../src/GovernanceToken.sol";

contract GovernanceTest is Test {
    Governance public gov;
    GovernanceToken public token;

    address public owner   = address(0x1);
    address public guardian = address(0x2);
    address public alice   = address(0x3);
    address public bob     = address(0x4);

    uint256 constant TIMELOCK = 2 days;
    uint256 constant VOTING_DELAY = 1 hours;
    uint256 constant VOTING_PERIOD = 3 days;
    uint256 constant PROPOSAL_THRESHOLD = 1000 ether;
    uint256 constant QUORUM = 10_000 ether;

    function setUp() public {
        // Deploy token
        vm.prank(owner);
        token = new GovernanceToken(owner);

        // Distribute
        vm.startPrank(owner);
        token.transfer(alice, 50_000 ether);
        token.transfer(bob,   20_000 ether);
        vm.stopPrank();

        // Deploy governance
        Governance implementation = new Governance();
        bytes memory initData = abi.encodeWithSelector(
            Governance.initialize.selector,
            address(token),
            TIMELOCK,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM,
            guardian,
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        gov = Governance(payable(address(proxy)));
    }

    // ─── Propose ───────────────────────────────────────────────────

    function test_Propose_Success() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _dummyProposal();

        vm.prank(alice);
        uint256 pid = gov.propose(targets, values, calldatas, "Test proposal");

        assertEq(pid, 1);
        assertEq(uint8(gov.state(pid)), uint8(Governance.ProposalState.Pending));
    }

    function test_Propose_BelowThresholdReverts() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _dummyProposal();

        address poorUser = address(0x99); // 0 tokens
        vm.prank(poorUser);
        vm.expectRevert("Governance: below proposal threshold");
        gov.propose(targets, values, calldatas, "Test");
    }

    function test_Propose_EmptyReverts() public {
        vm.prank(alice);
        vm.expectRevert("Governance: empty proposal");
        gov.propose(new address[](0), new uint256[](0), new bytes[](0), "Empty");
    }

    // ─── Voting ────────────────────────────────────────────────────

    function test_Vote_ForSucceeds() public {
        uint256 pid = _createAndActivateProposal();

        vm.prank(alice);
        gov.castVote(pid, 1);

        Governance.ProposalView memory p = gov.getProposal(pid);
        assertEq(p.forVotes, 50_000 ether);
    }

    function test_Vote_AgainstSucceeds() public {
        uint256 pid = _createAndActivateProposal();

        vm.prank(alice);
        gov.castVote(pid, 0);

        Governance.ProposalView memory p = gov.getProposal(pid);
        assertEq(p.againstVotes, 50_000 ether);
    }

    function test_Vote_AbstainSucceeds() public {
        uint256 pid = _createAndActivateProposal();

        vm.prank(alice);
        gov.castVote(pid, 2);

        Governance.ProposalView memory p = gov.getProposal(pid);
        assertEq(p.abstainVotes, 50_000 ether);
    }

    function test_Vote_DoubleVoteReverts() public {
        uint256 pid = _createAndActivateProposal();

        vm.prank(alice);
        gov.castVote(pid, 1);

        vm.prank(alice);
        vm.expectRevert("Governance: already voted");
        gov.castVote(pid, 1);
    }

    function test_Vote_NotActiveReverts() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _dummyProposal();
        vm.prank(alice);
        uint256 pid = gov.propose(targets, values, calldatas, "Test");

        // Still pending, not active
        vm.prank(alice);
        vm.expectRevert("Governance: proposal not active");
        gov.castVote(pid, 1);
    }

    function test_Vote_InvalidSupportReverts() public {
        uint256 pid = _createAndActivateProposal();

        vm.prank(alice);
        vm.expectRevert("Governance: invalid support value");
        gov.castVote(pid, 3);
    }

    // ─── Queue & Execute ───────────────────────────────────────────

    function test_Queue_AfterSuccess() public {
        uint256 pid = _passProposal();

        gov.queue(pid);
        assertEq(uint8(gov.state(pid)), uint8(Governance.ProposalState.Queued));
    }

    function test_Execute_AfterTimelock() public {
        uint256 pid = _passProposal();
        gov.queue(pid);

        vm.warp(block.timestamp + TIMELOCK + 1);
        gov.execute(pid);

        assertEq(uint8(gov.state(pid)), uint8(Governance.ProposalState.Executed));
    }

    function test_Execute_BeforeTimelockReverts() public {
        uint256 pid = _passProposal();
        gov.queue(pid);

        vm.expectRevert("Governance: timelock not elapsed");
        gov.execute(pid);
    }

    function test_Execute_AfterGracePeriodIsExpired() public {
        uint256 pid = _passProposal();
        gov.queue(pid);

        vm.warp(block.timestamp + TIMELOCK + gov.GRACE_PERIOD() + 1);
        assertEq(uint8(gov.state(pid)), uint8(Governance.ProposalState.Expired));
    }

    // ─── Cancel ────────────────────────────────────────────────────

    function test_Cancel_ByProposer() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _dummyProposal();
        vm.prank(alice);
        uint256 pid = gov.propose(targets, values, calldatas, "Test");

        vm.prank(alice);
        gov.cancel(pid);

        assertEq(uint8(gov.state(pid)), uint8(Governance.ProposalState.Cancelled));
    }

    function test_Cancel_ByGuardian() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _dummyProposal();
        vm.prank(alice);
        uint256 pid = gov.propose(targets, values, calldatas, "Test");

        vm.prank(guardian);
        gov.cancel(pid);

        assertEq(uint8(gov.state(pid)), uint8(Governance.ProposalState.Cancelled));
    }

    function test_Cancel_Unauthorized() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _dummyProposal();
        vm.prank(alice);
        uint256 pid = gov.propose(targets, values, calldatas, "Test");

        vm.prank(bob);
        vm.expectRevert("Governance: not proposer or guardian");
        gov.cancel(pid);
    }

    // ─── Defeat ────────────────────────────────────────────────────

    function test_State_DefeatedIfQuorumNotMet() public {
        uint256 pid = _createAndActivateProposal();

        address poorVoter = address(0xAA);
        vm.prank(owner);
        token.mint(poorVoter, 1 ether); // below quorum
        vm.prank(poorVoter);
        gov.castVote(pid, 1);

        // End voting
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        assertEq(uint8(gov.state(pid)), uint8(Governance.ProposalState.Defeated));
    }

    function test_State_DefeatedIfAgainstWins() public {
        uint256 pid = _createAndActivateProposal();

        vm.prank(alice); gov.castVote(pid, 0); // 50k against
        vm.prank(bob);   gov.castVote(pid, 1); // 20k for

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint8(gov.state(pid)), uint8(Governance.ProposalState.Defeated));
    }

    // ─── Parameter Updates ─────────────────────────────────────────

    function test_SetTimelockDelay_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        gov.setTimelockDelay(3 days);
    }

    function test_SetTimelockDelay_TooShortReverts() public {
        vm.prank(owner);
        vm.expectRevert("Governance: invalid delay");
        gov.setTimelockDelay(1 hours); // below MIN_TIMELOCK_DELAY
    }

    // ─── Additional Coverage ───────────────────────────────────────

    function test_GetVote_AfterCast() public {
        uint256 pid = _createAndActivateProposal();
        vm.prank(alice);
        gov.castVote(pid, 1);

        (bool hasVoted, uint8 support) = gov.getVote(pid, alice);
        assertTrue(hasVoted);
        assertEq(support, 1);
    }

    function test_GetVote_BeforeCast_IsFalse() public {
        uint256 pid = _createAndActivateProposal();
        (bool hasVoted,) = gov.getVote(pid, alice);
        assertFalse(hasVoted);
    }

    function test_Cancel_QueuedProposalClearsTimelock() public {
        uint256 pid = _passProposal();
        gov.queue(pid);
        assertEq(uint8(gov.state(pid)), uint8(Governance.ProposalState.Queued));

        vm.prank(guardian);
        gov.cancel(pid);
        assertEq(uint8(gov.state(pid)), uint8(Governance.ProposalState.Cancelled));
    }

    function test_ProposalCount_Increments() public {
        assertEq(gov.proposalCount(), 0);
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _dummyProposal();
        vm.prank(alice); gov.propose(t, v, c, "P1");
        assertEq(gov.proposalCount(), 1);
        vm.prank(alice); gov.propose(t, v, c, "P2");
        assertEq(gov.proposalCount(), 2);
    }

    function test_NoVotingPower_Reverts() public {
        address broke = address(0xBEEF);
        assertEq(token.balanceOf(broke), 0);
        uint256 pid = _createAndActivateProposal();
        vm.prank(broke);
        vm.expectRevert("Governance: no voting power");
        gov.castVote(pid, 1);
    }

    function test_SetGuardian_ByCurrentGuardian() public {
        address newGuardian = address(0x42);
        vm.prank(guardian);
        gov.setGuardian(newGuardian);
        assertEq(gov.guardian(), newGuardian);
    }

    function test_SetGuardian_Unauthorized_Reverts() public {
        vm.prank(alice);
        vm.expectRevert("Governance: unauthorized");
        gov.setGuardian(address(0x42));
    }

    function test_Queue_NotSucceededReverts() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _dummyProposal();
        vm.prank(alice);
        uint256 pid = gov.propose(t, v, c, "Pending proposal");
        vm.expectRevert("Governance: proposal not succeeded");
        gov.queue(pid);
    }

    function testFuzz_Propose_ArrayMismatchReverts(uint8 extraLen) public {
        vm.assume(extraLen > 0 && extraLen < 10);
        address[] memory targets   = new address[](1);
        uint256[] memory values    = new uint256[](1 + extraLen);
        bytes[]   memory calldatas = new bytes[](1);
        targets[0] = address(0xdead);

        vm.prank(alice);
        vm.expectRevert("Governance: array length mismatch");
        gov.propose(targets, values, calldatas, "Bad arrays");
    }

    function testFuzz_VoteWeight_MatchesTokenBalance(uint256 mintAmount) public {
        mintAmount = bound(mintAmount, 1 ether, 1_000_000 ether);
        address voter = address(0xCAFE);
        vm.prank(owner);
        token.mint(voter, mintAmount);

        uint256 pid = _createAndActivateProposal();
        vm.prank(voter);
        gov.castVote(pid, 1);

        Governance.ProposalView memory p = gov.getProposal(pid);
        // forVotes = alice's balance hasn't voted yet; voter cast 'for'
        assertEq(p.forVotes, mintAmount, "Vote weight must equal token balance");
    }

    // ─── Invariant ─────────────────────────────────────────────────

    function invariant_ExecutedProposalStaysExecuted() public view {
        uint256 count = gov.proposalCount();
        for (uint256 i = 1; i <= count; i++) {
            Governance.ProposalView memory p = gov.getProposal(i);
            if (p.executed) {
                assertEq(uint8(gov.state(i)), uint8(Governance.ProposalState.Executed),
                    "Executed proposal must stay executed");
            }
        }
    }

    // ─── Helpers ───────────────────────────────────────────────────

    function _dummyProposal() internal view returns (
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(0xdead); // no-op target
        calldatas[0] = "";
    }

    function _createAndActivateProposal() internal returns (uint256 pid) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _dummyProposal();
        vm.prank(alice);
        pid = gov.propose(targets, values, calldatas, "Active proposal");
        vm.warp(block.timestamp + VOTING_DELAY + 1);
    }

    function _passProposal() internal returns (uint256 pid) {
        pid = _createAndActivateProposal();
        vm.prank(alice); gov.castVote(pid, 1); // 50k for — meets quorum
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint8(gov.state(pid)), uint8(Governance.ProposalState.Succeeded));
    }
}
