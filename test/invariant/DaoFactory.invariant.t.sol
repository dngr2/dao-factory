// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DaoFactoryHandler} from "./DaoFactoryHandler.sol";
import {DaoFactory} from "../../src/DaoFactory.sol";
import {DaoToken} from "../../src/DaoToken.sol";
import {DaoGovernor} from "../../src/DaoGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title DaoFactoryInvariants
 * @notice Stateful invariant campaign over the DAO factory. It targets a handler that
 *         creates real DAOs and drives their tokens, and asserts the properties that
 *         would catch real bugs: the factory never keeps or leaks fees (each creation
 *         forwards exactly the live fee to the recipient and the factory holds no ETH),
 *         the registry stays consistent with the number of creations, every recorded DAO
 *         is a correctly-wired, self-sovereign token+timelock+governor triple with the
 *         params it was created with, and ERC20Votes voting power equals token balance
 *         for every delegated holder.
 */
contract DaoFactoryInvariants is StdInvariant, Test {
    DaoFactoryHandler internal handler;

    function setUp() public {
        handler = new DaoFactoryHandler();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.createDao.selector;
        selectors[1] = handler.setFee.selector;
        selectors[2] = handler.delegate.selector;
        selectors[3] = handler.transferToken.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice The recipient has received exactly the sum of fees charged per creation,
    ///         and the factory itself holds no ETH — fees can be neither skimmed nor stuck.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_feesFullyForwardedAndFactoryHoldsNothing() public view {
        assertEq(handler.feeRecipient().balance, handler.ghostFeesForwarded(), "fee recipient balance mismatch");
        assertEq(address(handler.factory()).balance, 0, "factory retained ETH");
    }

    /// @notice The factory registry count equals the number of successful creations.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_registryCountMatchesCreations() public view {
        assertEq(handler.factory().daoCount(), handler.ghostCreated(), "daoCount != creations");
        assertEq(handler.recsLength(), handler.ghostCreated(), "handler record count drift");
    }

    /// @notice Every recorded DAO is a correctly-wired, self-sovereign triple carrying the
    ///         exact params it was created with: governor bound to its token+timelock,
    ///         configured voting params preserved, governor holds PROPOSER/CANCELLER,
    ///         execution open to anyone, and the factory's admin role renounced.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyDaoWiredWithRecordedParams() public view {
        uint256 n = handler.recsLength();
        for (uint256 i; i < n; ++i) {
            (
                address token,
                address timelock,
                address governor,
                uint48 votingDelay,
                uint32 votingPeriod,
                uint256 proposalThreshold,
                uint256 quorumPercent,
                uint256 initialSupply,
                address initialHolder
            ) = handler.recs(i);

            DaoGovernor gov = DaoGovernor(payable(governor));
            TimelockController tl = TimelockController(payable(timelock));

            // Wiring.
            assertEq(address(gov.token()), token, "governor token binding");
            assertEq(gov.timelock(), timelock, "governor timelock binding");

            // Configured params preserved exactly.
            assertEq(gov.votingDelay(), votingDelay, "votingDelay");
            assertEq(gov.votingPeriod(), votingPeriod, "votingPeriod");
            assertEq(gov.proposalThreshold(), proposalThreshold, "proposalThreshold");
            assertEq(gov.quorumNumerator(), quorumPercent, "quorumPercent");

            // Token: recorded supply minted to the recorded holder at creation.
            assertEq(DaoToken(token).totalSupply(), initialSupply, "token supply");

            // Self-sovereign role wiring.
            assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), governor), "governor proposer");
            assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), governor), "governor canceller");
            assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "execution open");
            assertFalse(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(handler.factory())), "factory admin renounced");

            initialHolder; // recorded for provenance; balance-of-holder can shift via transfers
        }
    }

    /// @notice For every holder that has self-delegated on any created token, live voting
    ///         power equals their token balance — the ERC20Votes accounting the governor
    ///         relies on never diverges from balances.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_votingPowerEqualsBalanceForDelegated() public view {
        uint256 n = handler.recsLength();
        for (uint256 i; i < n; ++i) {
            (address token,,,,,,,,) = handler.recs(i);
            for (uint256 a; a < 4; ++a) {
                address actor = handler.actors(a);
                if (handler.selfDelegated(token, actor)) {
                    assertEq(
                        DaoToken(token).getVotes(actor),
                        DaoToken(token).balanceOf(actor),
                        "votes != balance for self-delegated holder"
                    );
                }
            }
        }
    }
}
