// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DaoFactory} from "../src/DaoFactory.sol";
import {TokenDeployer} from "../src/TokenDeployer.sol";
import {GovernorDeployer} from "../src/GovernorDeployer.sol";
import {DaoToken} from "../src/DaoToken.sol";
import {DaoGovernor} from "../src/DaoGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev A trivial governed target. Only its `owner` (the DAO timelock) may flip `value`.
contract Target {
    uint256 public value;
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function setValue(uint256 v) external {
        require(msg.sender == owner, "Target: not owner");
        value = v;
    }
}

/// @dev A fee recipient that rejects incoming ETH, to exercise the fee-transfer failure path.
contract RejectingRecipient {
    // no receive/fallback -> any ETH transfer reverts
}

/// @dev Shared harness: spins up a DAO via the factory and exposes lifecycle helpers.
abstract contract GovernanceBase is Test {
    DaoFactory factory;

    address feeRecipient = makeAddr("feeRecipient");
    address holder = makeAddr("holder");
    address stranger = makeAddr("stranger");

    uint256 constant INITIAL_FEE = 0.01 ether;
    uint256 constant SUPPLY = 1_000_000 ether;
    uint48 constant VOTING_DELAY = 1; // blocks
    uint32 constant VOTING_PERIOD = 50; // blocks
    uint256 constant QUORUM_PCT = 4; // percent -> quorum = 40_000 ether
    uint256 constant TIMELOCK_DELAY = 2 days; // seconds
    uint256 constant PROP_THRESHOLD = 1000 ether;

    // Support values per GovernorCountingSimple.VoteType
    uint8 constant AGAINST = 0;
    uint8 constant FOR = 1;
    uint8 constant ABSTAIN = 2;

    function setUp() public virtual {
        factory = new DaoFactory(new TokenDeployer(), new GovernorDeployer(), INITIAL_FEE, feeRecipient);
    }

    function _createDao() internal returns (DaoToken token, TimelockController tl, DaoGovernor gov) {
        (address t, address l, address g) = factory.createDao{value: INITIAL_FEE}(
            "Test DAO",
            "Test Token",
            "TST",
            SUPPLY,
            holder,
            VOTING_DELAY,
            VOTING_PERIOD,
            QUORUM_PCT,
            TIMELOCK_DELAY,
            PROP_THRESHOLD
        );
        return (DaoToken(t), TimelockController(payable(l)), DaoGovernor(payable(g)));
    }

    /// @dev Build a single-call proposal payload.
    function _single(address target, bytes memory data)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = target;
        values[0] = 0;
        calldatas[0] = data;
    }

    /// @dev Activate an account's voting power for a delegatee, then advance one block so the
    ///      checkpoint is in the past (delegation snapshots read past state).
    function _delegate(DaoToken token, address from, address to) internal {
        vm.prank(from);
        token.delegate(to);
        vm.roll(block.number + 1);
    }
}

/// @notice Adversarial + full-lifecycle governance coverage for the factory-produced DAO stack.
contract DaoGovernanceAdversarialTest is GovernanceBase {
    // ------------------------------------------------------------------
    // Quorum boundary: exactly met vs one vote short
    // ------------------------------------------------------------------

    function _proposeAndReachDeadline(DaoGovernor gov, address voter, uint8 support)
        internal
        returns (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        (targets, values, calldatas) = _single(address(0xdead), abi.encodeWithSignature("noop()"));
        vm.prank(voter);
        proposalId = gov.propose(targets, values, calldatas, "boundary");
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(voter);
        gov.castVote(proposalId, support);
        vm.roll(block.number + VOTING_PERIOD + 1);
    }

    function test_Quorum_ExactlyMet_Succeeds() public {
        (DaoToken token,, DaoGovernor gov) = _createDao();
        uint256 quorumVotes = (SUPPLY * QUORUM_PCT) / 100; // 40_000 ether

        address voter = makeAddr("exactVoter");
        vm.prank(holder);
        token.transfer(voter, quorumVotes);
        _delegate(token, voter, voter);

        (uint256 id,,,) = _proposeAndReachDeadline(gov, voter, FOR);
        // forVotes == quorum -> reached (<=), forVotes > againstVotes -> succeeded
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Succeeded), "exact quorum succeeds");
    }

    function test_Quorum_OneVoteShort_Defeated() public {
        (DaoToken token,, DaoGovernor gov) = _createDao();
        uint256 quorumVotes = (SUPPLY * QUORUM_PCT) / 100;

        address voter = makeAddr("shortVoter");
        vm.prank(holder);
        token.transfer(voter, quorumVotes - 1); // one wei of votes short
        _delegate(token, voter, voter);

        (uint256 id,,,) = _proposeAndReachDeadline(gov, voter, FOR);
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Defeated), "one short defeated");
    }

    // ------------------------------------------------------------------
    // Vote tally: defeated when against >= for, even with quorum
    // ------------------------------------------------------------------

    function test_Defeated_AgainstOutweighsFor() public {
        (DaoToken token,, DaoGovernor gov) = _createDao();
        uint256 quorumVotes = (SUPPLY * QUORUM_PCT) / 100;

        // Voter has quorum met but votes Against -> quorum reached, but not succeeded.
        address voter = makeAddr("noVoter");
        vm.prank(holder);
        token.transfer(voter, quorumVotes + 10 ether);
        _delegate(token, voter, voter);

        (uint256 id,,,) = _proposeAndReachDeadline(gov, voter, AGAINST);
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Defeated), "against defeats");
    }

    function test_Defeated_TieIsNotSuccess() public {
        (DaoToken token,, DaoGovernor gov) = _createDao();
        uint256 half = (SUPPLY * QUORUM_PCT) / 100 + 10 ether;

        address forVoter = makeAddr("forVoter");
        address againstVoter = makeAddr("againstVoter");
        vm.prank(holder);
        token.transfer(forVoter, half);
        vm.prank(holder);
        token.transfer(againstVoter, half);
        _delegate(token, forVoter, forVoter);
        _delegate(token, againstVoter, againstVoter);

        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(0xdead), abi.encodeWithSignature("noop()"));
        vm.prank(forVoter);
        uint256 id = gov.propose(t, v, c, "tie");
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(forVoter);
        gov.castVote(id, FOR);
        vm.prank(againstVoter);
        gov.castVote(id, AGAINST);
        vm.roll(block.number + VOTING_PERIOD + 1);
        // forVotes == againstVotes -> _voteSucceeded requires strictly greater -> Defeated
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Defeated), "tie is defeat");
    }

    // ------------------------------------------------------------------
    // Double-vote / vote-change reverts
    // ------------------------------------------------------------------

    function test_DoubleVote_Reverts() public {
        (DaoToken token,, DaoGovernor gov) = _createDao();
        _delegate(token, holder, holder);

        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(0xdead), abi.encodeWithSignature("noop()"));
        vm.prank(holder);
        uint256 id = gov.propose(t, v, c, "double");
        vm.roll(block.number + VOTING_DELAY + 1);

        vm.prank(holder);
        gov.castVote(id, FOR);

        // Second cast (even to change the vote) reverts.
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorAlreadyCastVote.selector, holder));
        gov.castVote(id, AGAINST);
    }

    // ------------------------------------------------------------------
    // Proposal threshold
    // ------------------------------------------------------------------

    function test_Propose_AtThreshold_Succeeds() public {
        (DaoToken token,, DaoGovernor gov) = _createDao();
        // Exactly threshold votes is enough (check is strict `<`).
        vm.prank(holder);
        token.transfer(stranger, PROP_THRESHOLD);
        _delegate(token, stranger, stranger);

        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(0xdead), abi.encodeWithSignature("noop()"));
        vm.prank(stranger);
        uint256 id = gov.propose(t, v, c, "at threshold");
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Pending), "proposed at threshold");
    }

    function test_Propose_OneBelowThreshold_Reverts() public {
        (DaoToken token,, DaoGovernor gov) = _createDao();
        vm.prank(holder);
        token.transfer(stranger, PROP_THRESHOLD - 1);
        _delegate(token, stranger, stranger);

        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(0xdead), abi.encodeWithSignature("noop()"));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector, stranger, PROP_THRESHOLD - 1, PROP_THRESHOLD
            )
        );
        gov.propose(t, v, c, "below");
    }

    // ------------------------------------------------------------------
    // Cancel: proposer vs non-proposer, and state constraints
    // ------------------------------------------------------------------

    function test_Cancel_ByProposer_WhilePending() public {
        (DaoToken token,, DaoGovernor gov) = _createDao();
        _delegate(token, holder, holder);

        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(0xdead), abi.encodeWithSignature("noop()"));
        vm.prank(holder);
        uint256 id = gov.propose(t, v, c, "cancelme");

        vm.prank(holder);
        gov.cancel(t, v, c, keccak256(bytes("cancelme")));
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Canceled), "canceled by proposer");
    }

    function test_Cancel_ByNonProposer_Reverts() public {
        (DaoToken token,, DaoGovernor gov) = _createDao();
        _delegate(token, holder, holder);

        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(0xdead), abi.encodeWithSignature("noop()"));
        vm.prank(holder);
        gov.propose(t, v, c, "cancelme");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyProposer.selector, stranger));
        gov.cancel(t, v, c, keccak256(bytes("cancelme")));
    }

    function test_Cancel_AfterActive_Reverts() public {
        (DaoToken token,, DaoGovernor gov) = _createDao();
        _delegate(token, holder, holder);

        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(0xdead), abi.encodeWithSignature("noop()"));
        vm.prank(holder);
        gov.propose(t, v, c, "cancelme");
        vm.roll(block.number + VOTING_DELAY + 1); // now Active

        // Proposer can no longer cancel once voting is Active (public cancel only allows Pending).
        vm.prank(holder);
        vm.expectRevert(); // GovernorUnexpectedProposalState
        gov.cancel(t, v, c, keccak256(bytes("cancelme")));
    }

    // ------------------------------------------------------------------
    // Timelock delay enforcement on execution
    // ------------------------------------------------------------------

    function _passingProposalToTarget(DaoGovernor gov, Target target, uint256 newVal)
        internal
        returns (
            uint256 id,
            address[] memory t,
            uint256[] memory v,
            bytes[] memory c,
            bytes32 descHash,
            string memory desc
        )
    {
        desc = "set value";
        descHash = keccak256(bytes(desc));
        (t, v, c) = _single(address(target), abi.encodeCall(Target.setValue, (newVal)));
        vm.prank(holder);
        id = gov.propose(t, v, c, desc);
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(holder);
        gov.castVote(id, FOR);
        vm.roll(block.number + VOTING_PERIOD + 1);
    }

    function test_Execute_BeforeTimelockDelay_Reverts() public {
        (DaoToken token, TimelockController tl, DaoGovernor gov) = _createDao();
        _delegate(token, holder, holder);
        Target target = new Target(address(tl));

        (, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h,) =
            _passingProposalToTarget(gov, target, 7);

        gov.queue(t, v, c, h);
        // No warp: timelock op not yet ready.
        vm.expectRevert(); // TimelockController.TimelockUnexpectedOperationState
        gov.execute(t, v, c, h);
    }

    function test_Execute_AfterDelay_Succeeds() public {
        (DaoToken token, TimelockController tl, DaoGovernor gov) = _createDao();
        _delegate(token, holder, holder);
        Target target = new Target(address(tl));

        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h,) =
            _passingProposalToTarget(gov, target, 7);

        gov.queue(t, v, c, h);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        gov.execute(t, v, c, h);
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Executed), "executed after delay");
        assertEq(target.value(), 7, "governed effect applied");
    }

    function test_Execute_JustBeforeDelay_Reverts() public {
        (DaoToken token, TimelockController tl, DaoGovernor gov) = _createDao();
        _delegate(token, holder, holder);
        Target target = new Target(address(tl));

        (, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h,) =
            _passingProposalToTarget(gov, target, 7);

        gov.queue(t, v, c, h);
        // One second short of the delay.
        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);
        vm.expectRevert();
        gov.execute(t, v, c, h);
    }

    // ------------------------------------------------------------------
    // Executing invalid proposals
    // ------------------------------------------------------------------

    function test_Execute_Unqueued_Reverts() public {
        (DaoToken token, TimelockController tl, DaoGovernor gov) = _createDao();
        _delegate(token, holder, holder);
        Target target = new Target(address(tl));

        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h,) =
            _passingProposalToTarget(gov, target, 7);
        // Succeeded but never queued.
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Succeeded), "succeeded, not queued");
        vm.expectRevert(); // timelock op was never scheduled
        gov.execute(t, v, c, h);
    }

    function test_Execute_Defeated_Reverts() public {
        (DaoToken token, TimelockController tl, DaoGovernor gov) = _createDao();
        _delegate(token, holder, holder);
        Target target = new Target(address(tl));

        string memory desc = "defeated";
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(target), abi.encodeCall(Target.setValue, (7)));
        vm.prank(holder);
        uint256 id = gov.propose(t, v, c, desc);
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(holder);
        gov.castVote(id, AGAINST); // holder is the only voter, votes against
        vm.roll(block.number + VOTING_PERIOD + 1);
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Defeated), "defeated");

        vm.expectRevert(); // GovernorUnexpectedProposalState
        gov.execute(t, v, c, keccak256(bytes(desc)));
    }

    function test_Queue_Defeated_Reverts() public {
        (DaoToken token, TimelockController tl, DaoGovernor gov) = _createDao();
        _delegate(token, holder, holder);
        Target target = new Target(address(tl));

        string memory desc = "defeated-queue";
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(target), abi.encodeCall(Target.setValue, (7)));
        vm.prank(holder);
        uint256 id = gov.propose(t, v, c, desc);
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(holder);
        gov.castVote(id, AGAINST);
        vm.roll(block.number + VOTING_PERIOD + 1);
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Defeated), "defeated");

        vm.expectRevert(); // cannot queue a non-succeeded proposal
        gov.queue(t, v, c, keccak256(bytes(desc)));
    }

    // ------------------------------------------------------------------
    // Only the timelock (through governance) can mutate governor settings
    // ------------------------------------------------------------------

    function test_Settings_DirectSetVotingDelay_Reverts() public {
        (,, DaoGovernor gov) = _createDao();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, stranger));
        gov.setVotingDelay(99);
    }

    function test_Settings_DirectUpdateQuorum_Reverts() public {
        (,, DaoGovernor gov) = _createDao();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, stranger));
        gov.updateQuorumNumerator(50);
    }

    function test_Settings_ChangedViaPassedProposal() public {
        (DaoToken token, TimelockController tl, DaoGovernor gov) = _createDao();
        _delegate(token, holder, holder);
        assertEq(gov.votingDelay(), VOTING_DELAY, "delay before");

        uint256 newDelay = 10;
        string memory desc = "raise voting delay";
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(gov), abi.encodeCall(gov.setVotingDelay, (uint48(newDelay))));

        vm.prank(holder);
        uint256 id = gov.propose(t, v, c, desc);
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(holder);
        gov.castVote(id, FOR);
        vm.roll(block.number + VOTING_PERIOD + 1);

        gov.queue(t, v, c, keccak256(bytes(desc)));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        gov.execute(t, v, c, keccak256(bytes(desc)));

        assertEq(gov.votingDelay(), newDelay, "delay changed by governance");
        // sanity: the timelock, not the factory or deployer, drove the change
        assertEq(gov.timelock(), address(tl), "timelock unchanged");
    }

    function test_Settings_QuorumChangedViaPassedProposal() public {
        (DaoToken token,, DaoGovernor gov) = _createDao();
        _delegate(token, holder, holder);

        uint256 newNumerator = 10; // 10%
        string memory desc = "raise quorum to 10pct";
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(gov), abi.encodeCall(gov.updateQuorumNumerator, (newNumerator)));

        vm.prank(holder);
        uint256 id = gov.propose(t, v, c, desc);
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(holder);
        gov.castVote(id, FOR);
        vm.roll(block.number + VOTING_PERIOD + 1);
        gov.queue(t, v, c, keccak256(bytes(desc)));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        gov.execute(t, v, c, keccak256(bytes(desc)));

        assertEq(gov.quorumNumerator(), newNumerator, "quorum numerator changed by governance");
    }

    // ------------------------------------------------------------------
    // Factory isolation: two DAOs share no state
    // ------------------------------------------------------------------

    function test_TwoDaos_AreIsolated() public {
        (DaoToken tokenA, TimelockController tlA, DaoGovernor govA) = _createDao();

        // second DAO with a different holder + supply
        address holderB = makeAddr("holderB");
        (address tB, address lB, address gB) = factory.createDao{value: INITIAL_FEE}(
            "DAO B",
            "TokB",
            "TKB",
            2 * SUPPLY,
            holderB,
            VOTING_DELAY,
            VOTING_PERIOD,
            QUORUM_PCT,
            TIMELOCK_DELAY,
            PROP_THRESHOLD
        );
        DaoToken tokenB = DaoToken(tB);
        DaoGovernor govB = DaoGovernor(payable(gB));

        // distinct instances
        assertTrue(address(tokenA) != tB, "distinct tokens");
        assertTrue(address(govA) != gB, "distinct governors");
        assertTrue(address(tlA) != lB, "distinct timelocks");

        // independent balances/supply
        assertEq(tokenA.totalSupply(), SUPPLY);
        assertEq(tokenB.totalSupply(), 2 * SUPPLY);
        assertEq(tokenA.balanceOf(holderB), 0, "B holder has no A tokens");
        assertEq(tokenB.balanceOf(holder), 0, "A holder has no B tokens");

        // votes in A do not appear in B
        _delegate(tokenA, holder, holder);
        assertEq(govA.getVotes(holder, block.number - 1), SUPPLY, "A votes");
        assertEq(govB.getVotes(holder, block.number - 1), 0, "no cross votes in B");

        // factory records both, in order
        assertEq(factory.daoCount(), 2, "two daos");
        (address t0,,) = factory.getDao(0);
        (address t1,,) = factory.getDao(1);
        assertEq(t0, address(tokenA));
        assertEq(t1, tB);
    }

    // ------------------------------------------------------------------
    // Delegation edge cases
    // ------------------------------------------------------------------

    function test_Delegation_NoVotesUntilDelegated() public {
        (DaoToken token,,) = _createDao();
        // Holder owns the full supply but has never delegated -> zero voting power.
        assertEq(token.getVotes(holder), 0, "undelegated tokens carry no votes");
        _delegate(token, holder, holder);
        assertEq(token.getVotes(holder), SUPPLY, "self-delegation activates votes");
    }

    function test_Delegation_RedelegateMidProposal_UsesSnapshot() public {
        (DaoToken token,, DaoGovernor gov) = _createDao();
        address delegateA = makeAddr("delegateA");
        address delegateB = makeAddr("delegateB");

        // Holder delegates all voting power to A and lets it checkpoint.
        _delegate(token, holder, delegateA);

        // Propose (proposer must itself clear threshold; delegate to holder-self first for proposing).
        // Use delegateA as proposer since it now holds the votes.
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(0xdead), abi.encodeWithSignature("noop()"));
        vm.prank(delegateA);
        uint256 id = gov.propose(t, v, c, "snapshot test");

        // Move to Active so the vote snapshot (proposalSnapshot) is now fixed in the past.
        vm.roll(block.number + VOTING_DELAY + 1);

        // Holder re-delegates to B *after* the snapshot.
        vm.prank(holder);
        token.delegate(delegateB);
        vm.roll(block.number + 1);

        // B has current votes but ZERO at the snapshot -> its vote carries no weight.
        vm.prank(delegateB);
        gov.castVote(id, FOR);
        (, uint256 forAfterB,) = gov.proposalVotes(id);
        assertEq(forAfterB, 0, "post-snapshot delegatee has no snapshot weight");

        // A still had the full weight at the snapshot -> its vote counts fully.
        vm.prank(delegateA);
        gov.castVote(id, FOR);
        (, uint256 forAfterA,) = gov.proposalVotes(id);
        assertEq(forAfterA, SUPPLY, "snapshot weight preserved for original delegatee");
    }

    function test_Delegation_ReDelegateMovesFutureVotes() public {
        (DaoToken token,,) = _createDao();
        _delegate(token, holder, holder);
        assertEq(token.getVotes(holder), SUPPLY);

        address newDelegate = makeAddr("newDelegate");
        vm.prank(holder);
        token.delegate(newDelegate);
        vm.roll(block.number + 1);

        assertEq(token.getVotes(holder), 0, "votes moved off holder");
        assertEq(token.getVotes(newDelegate), SUPPLY, "votes moved to new delegate");
    }

    // ------------------------------------------------------------------
    // Fee surface: failure path + boundary + zero-address guards
    // ------------------------------------------------------------------

    function test_Fee_TransferFailure_Reverts() public {
        // Point the fee at a contract that rejects ETH.
        RejectingRecipient bad = new RejectingRecipient();
        DaoFactory f = new DaoFactory(new TokenDeployer(), new GovernorDeployer(), INITIAL_FEE, address(bad));

        vm.expectRevert("DaoFactory: fee transfer failed");
        f.createDao{value: INITIAL_FEE}(
            "DAO", "Tok", "TK", SUPPLY, holder, VOTING_DELAY, VOTING_PERIOD, QUORUM_PCT, TIMELOCK_DELAY, PROP_THRESHOLD
        );
    }

    function test_Fee_AtCapExactly_Allowed() public {
        uint256 cap = factory.MAX_FEE();
        DaoFactory f = new DaoFactory(new TokenDeployer(), new GovernorDeployer(), cap, feeRecipient);
        assertEq(f.fee(), cap, "constructed at cap");
    }

    function test_Fee_WrongValue_UnderAndOver_Revert() public {
        vm.expectRevert("DaoFactory: wrong fee");
        factory.createDao{value: INITIAL_FEE - 1}(
            "DAO", "Tok", "TK", SUPPLY, holder, VOTING_DELAY, VOTING_PERIOD, QUORUM_PCT, TIMELOCK_DELAY, PROP_THRESHOLD
        );
        vm.expectRevert("DaoFactory: wrong fee");
        factory.createDao{value: INITIAL_FEE + 1}(
            "DAO", "Tok", "TK", SUPPLY, holder, VOTING_DELAY, VOTING_PERIOD, QUORUM_PCT, TIMELOCK_DELAY, PROP_THRESHOLD
        );
    }

    function test_Constructor_ZeroRecipient_Reverts() public {
        TokenDeployer td = new TokenDeployer();
        GovernorDeployer gd = new GovernorDeployer();
        vm.expectRevert("DaoFactory: recipient is zero");
        new DaoFactory(td, gd, INITIAL_FEE, address(0));
    }

    function test_SetFeeRecipient_ZeroReverts() public {
        vm.expectRevert("DaoFactory: recipient is zero");
        factory.setFeeRecipient(address(0));
    }

    function test_CreateDao_QuorumOver100_Reverts() public {
        vm.expectRevert("DaoFactory: quorum > 100");
        factory.createDao{value: INITIAL_FEE}(
            "DAO", "Tok", "TK", SUPPLY, holder, VOTING_DELAY, VOTING_PERIOD, 101, TIMELOCK_DELAY, PROP_THRESHOLD
        );
    }

    function test_Ownership_TransferAndRenounce() public {
        address newOwner = makeAddr("newOwner");
        factory.transferOwnership(newOwner);
        assertEq(factory.owner(), newOwner);

        // Old owner (this) can no longer set fee.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.setFee(0);

        // New owner can.
        vm.prank(newOwner);
        factory.setFee(0);
        assertEq(factory.fee(), 0);
    }

    // ------------------------------------------------------------------
    // Anyone may execute (open executor role) once queued & ready
    // ------------------------------------------------------------------

    function test_Execute_ByStranger_Allowed_WhenReady() public {
        (DaoToken token, TimelockController tl, DaoGovernor gov) = _createDao();
        _delegate(token, holder, holder);
        Target target = new Target(address(tl));

        (, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h,) =
            _passingProposalToTarget(gov, target, 55);
        gov.queue(t, v, c, h);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Governor.execute is public; a random account can trigger a ready, queued proposal.
        vm.prank(stranger);
        gov.execute(t, v, c, h);
        assertEq(target.value(), 55, "stranger triggered ready execution");
    }

    // fund this test contract if a refund ever occurs
    receive() external payable {}
}
