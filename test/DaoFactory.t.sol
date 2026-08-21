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
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev A trivial governed target. Only the DAO's timelock may flip `value`.
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

contract DaoFactoryTest is Test {
    DaoFactory factory;

    address deployer = address(this);
    address feeRecipient = makeAddr("feeRecipient");
    address holder = makeAddr("holder");
    address stranger = makeAddr("stranger");

    uint256 constant INITIAL_FEE = 0.01 ether;
    uint256 constant SUPPLY = 1_000_000 ether;
    uint48 constant VOTING_DELAY = 1; // blocks
    uint32 constant VOTING_PERIOD = 50; // blocks
    uint256 constant QUORUM_PCT = 4; // percent
    uint256 constant TIMELOCK_DELAY = 2 days; // seconds
    uint256 constant PROP_THRESHOLD = 1000 ether;

    function setUp() public {
        factory = new DaoFactory(new TokenDeployer(), new GovernorDeployer(), INITIAL_FEE, feeRecipient);
    }

    // --- helpers ---

    function _createDefaultDao() internal returns (DaoToken token, TimelockController tl, DaoGovernor gov) {
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

    // ----------------------------------------------------------------------
    // Deployment & wiring
    // ----------------------------------------------------------------------

    function test_Deploy_TokenSupplyAndHolder() public {
        (DaoToken token,,) = _createDefaultDao();
        assertEq(token.totalSupply(), SUPPLY, "total supply");
        assertEq(token.balanceOf(holder), SUPPLY, "holder balance");
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TST");
    }

    function test_Deploy_GovernorBoundToTokenAndTimelock() public {
        (DaoToken token, TimelockController tl, DaoGovernor gov) = _createDefaultDao();
        assertEq(address(gov.token()), address(token), "governor token");
        assertEq(gov.timelock(), address(tl), "governor timelock");
        assertEq(gov.votingDelay(), VOTING_DELAY, "voting delay");
        assertEq(gov.votingPeriod(), VOTING_PERIOD, "voting period");
        assertEq(gov.proposalThreshold(), PROP_THRESHOLD, "proposal threshold");
        // quorum = 4% of supply at a past timepoint
        vm.roll(block.number + 1);
        assertEq(gov.quorum(block.number - 1), (SUPPLY * QUORUM_PCT) / 100, "quorum");
    }

    function test_Deploy_RolesWiredAndAdminRenounced() public {
        (, TimelockController tl, DaoGovernor gov) = _createDefaultDao();
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), address(gov)), "governor is proposer");
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), address(gov)), "governor is canceller");
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "executor open to anyone");
        assertFalse(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(factory)), "factory admin renounced");
        assertTrue(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(tl)), "timelock self-administers");
    }

    function test_Deploy_IndexedAndCounted() public {
        (address t, address l, address g) = factory.createDao{value: INITIAL_FEE}(
            "DAO", "Tok", "TK", SUPPLY, holder, VOTING_DELAY, VOTING_PERIOD, QUORUM_PCT, TIMELOCK_DELAY, PROP_THRESHOLD
        );
        assertEq(factory.daoCount(), 1);
        (address t2, address l2, address g2) = factory.getDao(0);
        assertEq(t, t2);
        assertEq(l, l2);
        assertEq(g, g2);
    }

    // ----------------------------------------------------------------------
    // Full proposal lifecycle: propose -> vote -> queue -> execute
    // ----------------------------------------------------------------------

    function test_FullLifecycle_ProposeVoteQueueExecute() public {
        (DaoToken token, TimelockController tl, DaoGovernor gov) = _createDefaultDao();

        // Target owned by the timelock: only the DAO can change it.
        Target target = new Target(address(tl));
        assertEq(target.value(), 0);

        // Holder activates voting power by self-delegating.
        vm.prank(holder);
        token.delegate(holder);
        vm.roll(block.number + 1); // checkpoint takes effect next block
        assertEq(token.getVotes(holder), SUPPLY, "votes active");

        // Build the proposal: timelock calls target.setValue(42).
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(target);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(Target.setValue, (42));
        string memory description = "Set target value to 42";

        // Propose.
        vm.prank(holder);
        uint256 proposalId = gov.propose(targets, values, calldatas, description);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Pending), "pending");

        // Past voting delay -> Active.
        vm.roll(block.number + VOTING_DELAY + 1);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Active), "active");

        // Vote For (support = 1).
        vm.prank(holder);
        gov.castVote(proposalId, 1);

        // Past voting period -> Succeeded.
        vm.roll(block.number + VOTING_PERIOD + 1);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded), "succeeded");

        // Queue into the timelock.
        bytes32 descHash = keccak256(bytes(description));
        gov.queue(targets, values, calldatas, descHash);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Queued), "queued");

        // Warp past the timelock delay, then execute.
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        gov.execute(targets, values, calldatas, descHash);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Executed), "executed");

        // Governed state actually changed.
        assertEq(target.value(), 42, "target updated by DAO");
    }

    function test_FullLifecycle_TreasuryTransferByDao() public {
        // A second flavor: the timelock holds tokens and the DAO votes to move them.
        (DaoToken token, TimelockController tl, DaoGovernor gov) = _createDefaultDao();

        // Fund the timelock treasury from the holder.
        vm.prank(holder);
        token.transfer(address(tl), 500 ether);

        vm.prank(holder);
        token.delegate(holder);
        vm.roll(block.number + 1);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(token);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(token.transfer, (stranger, 500 ether));
        string memory description = "Pay 500 to stranger";

        vm.prank(holder);
        uint256 proposalId = gov.propose(targets, values, calldatas, description);
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(holder);
        gov.castVote(proposalId, 1);
        vm.roll(block.number + VOTING_PERIOD + 1);

        bytes32 descHash = keccak256(bytes(description));
        gov.queue(targets, values, calldatas, descHash);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        gov.execute(targets, values, calldatas, descHash);

        assertEq(token.balanceOf(stranger), 500 ether, "treasury paid stranger");
        assertEq(token.balanceOf(address(tl)), 0, "treasury drained");
    }

    // ----------------------------------------------------------------------
    // Negative paths
    // ----------------------------------------------------------------------

    function test_Defeated_WhenQuorumNotMet() public {
        // A tiny holder self-delegates; their votes cannot reach 4% quorum.
        (DaoToken token,, DaoGovernor gov) = _createDefaultDao();
        address whale = holder;
        address minnow = makeAddr("minnow");

        // whale delegates so proposals can be created, but minnow casts the only vote.
        vm.prank(whale);
        token.transfer(minnow, PROP_THRESHOLD); // enough to propose, far below quorum
        vm.prank(minnow);
        token.delegate(minnow);
        vm.prank(whale);
        token.delegate(whale);
        vm.roll(block.number + 1);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(token);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(token.transfer, (stranger, 1));
        string memory description = "low turnout";

        vm.prank(minnow);
        uint256 proposalId = gov.propose(targets, values, calldatas, description);
        vm.roll(block.number + VOTING_DELAY + 1);

        // Only the minnow votes For -> below 4% quorum.
        vm.prank(minnow);
        gov.castVote(proposalId, 1);
        vm.roll(block.number + VOTING_PERIOD + 1);

        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Defeated), "defeated: no quorum");
    }

    function test_Propose_RevertsBelowThreshold() public {
        (DaoToken token,, DaoGovernor gov) = _createDefaultDao();

        // stranger holds just under the threshold and delegates to self.
        vm.prank(holder);
        token.transfer(stranger, PROP_THRESHOLD - 1);
        vm.prank(stranger);
        token.delegate(stranger);
        vm.roll(block.number + 1);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(token);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(token.transfer, (holder, 1));

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector, stranger, PROP_THRESHOLD - 1, PROP_THRESHOLD
            )
        );
        gov.propose(targets, values, calldatas, "should revert");
    }

    function test_GovernedAction_OnlyTimelockCanCall() public {
        (, TimelockController tl,) = _createDefaultDao();
        Target target = new Target(address(tl));

        // A random caller cannot flip the governed value directly.
        vm.prank(stranger);
        vm.expectRevert("Target: not owner");
        target.setValue(99);

        // The timelock (as the DAO's executor) can.
        vm.prank(address(tl));
        target.setValue(99);
        assertEq(target.value(), 99);
    }

    // ----------------------------------------------------------------------
    // Protocol fee
    // ----------------------------------------------------------------------

    function test_Fee_ForwardedToRecipient() public {
        uint256 before = feeRecipient.balance;
        _createDefaultDao();
        assertEq(feeRecipient.balance - before, INITIAL_FEE, "fee forwarded");
    }

    function test_Fee_RevertsOnWrongValue() public {
        vm.expectRevert("DaoFactory: wrong fee");
        factory.createDao{value: INITIAL_FEE + 1}(
            "DAO", "Tok", "TK", SUPPLY, holder, VOTING_DELAY, VOTING_PERIOD, QUORUM_PCT, TIMELOCK_DELAY, PROP_THRESHOLD
        );

        vm.expectRevert("DaoFactory: wrong fee");
        factory.createDao{value: 0}(
            "DAO", "Tok", "TK", SUPPLY, holder, VOTING_DELAY, VOTING_PERIOD, QUORUM_PCT, TIMELOCK_DELAY, PROP_THRESHOLD
        );
    }

    function test_Fee_CapEnforcedOnConstruct() public {
        uint256 maxFee = factory.MAX_FEE();
        TokenDeployer td = new TokenDeployer();
        GovernorDeployer gd = new GovernorDeployer();
        vm.expectRevert("DaoFactory: fee over cap");
        new DaoFactory(td, gd, maxFee + 1, feeRecipient);
    }

    function test_Fee_CapEnforcedOnSetFee() public {
        uint256 maxFee = factory.MAX_FEE();
        vm.expectRevert("DaoFactory: fee over cap");
        factory.setFee(maxFee + 1);

        factory.setFee(maxFee); // at the cap is allowed
        assertEq(factory.fee(), maxFee);
    }

    function test_Fee_OnlyOwnerCanSet() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.setFee(0.02 ether);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.setFeeRecipient(stranger);
    }

    function test_Fee_ZeroFeeDeploysFree() public {
        factory.setFee(0);
        uint256 before = feeRecipient.balance;
        (address t,,) = factory.createDao{value: 0}(
            "Free DAO",
            "Free",
            "FREE",
            SUPPLY,
            holder,
            VOTING_DELAY,
            VOTING_PERIOD,
            QUORUM_PCT,
            TIMELOCK_DELAY,
            PROP_THRESHOLD
        );
        assertTrue(t != address(0));
        assertEq(feeRecipient.balance, before, "no fee moved");
    }

    function test_SetFeeRecipient_Updates() public {
        address newRecipient = makeAddr("newRecipient");
        factory.setFeeRecipient(newRecipient);
        assertEq(factory.feeRecipient(), newRecipient);

        uint256 before = newRecipient.balance;
        _createDefaultDao();
        assertEq(newRecipient.balance - before, INITIAL_FEE, "fee to new recipient");
    }

    // allow this test contract to receive ETH if ever refunded
    receive() external payable {}
}
