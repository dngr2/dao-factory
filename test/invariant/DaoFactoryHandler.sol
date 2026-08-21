// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DaoFactory} from "../../src/DaoFactory.sol";
import {TokenDeployer} from "../../src/TokenDeployer.sol";
import {GovernorDeployer} from "../../src/GovernorDeployer.sol";
import {DaoToken} from "../../src/DaoToken.sol";
import {DaoGovernor} from "../../src/DaoGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @notice Stateful handler that creates real DAOs through the factory and then exercises
 *         the created tokens (self-delegation + transfers) and fee configuration, so an
 *         invariant campaign checks the actual factory accounting and wiring: exact
 *         per-creation fee collection, self-sovereign role wiring, configured governor
 *         params, and ERC20Votes voting-power == balance for delegated holders.
 *
 * @dev The handler owns the factory (it deploys it), so owner-gated setFee needs no
 *      prank. Every createDao is funded with exactly the live fee and its params are
 *      bounded to valid ranges, so calls land instead of reverting. Creation is capped so
 *      the per-call invariant sweep over all DAOs stays cheap. Ghost state mirrors the
 *      recorded params and the running fee total for the invariants to verify.
 */
contract DaoFactoryHandler is Test {
    DaoFactory public factory;
    address public feeRecipient = makeAddr("feeRecipient");

    uint256 public constant MAX_DAOS = 8;

    struct Rec {
        address token;
        address timelock;
        address governor;
        uint48 votingDelay;
        uint32 votingPeriod;
        uint256 proposalThreshold;
        uint256 quorumPercent;
        uint256 initialSupply;
        address initialHolder;
    }

    Rec[] public recs;

    address[4] public actors;

    // ghost ledgers
    uint256 public ghostFeesForwarded; // sum of fee charged per createDao
    uint256 public ghostCreated; // number of createDao calls that deployed a DAO

    // (token => (actor => self-delegated?))
    mapping(address => mapping(address => bool)) public selfDelegated;

    constructor() {
        factory = new DaoFactory(new TokenDeployer(), new GovernorDeployer(), 0.01 ether, feeRecipient);
        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");
        actors[3] = makeAddr("dave");
    }

    function recsLength() external view returns (uint256) {
        return recs.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    // --------------------------------------------------------------------- //
    //                             createDao                                 //
    // --------------------------------------------------------------------- //

    function createDao(
        uint256 supplySeed,
        uint256 holderSeed,
        uint256 votingDelaySeed,
        uint256 votingPeriodSeed,
        uint256 quorumSeed,
        uint256 timelockSeed,
        uint256 thresholdSeed
    ) public {
        if (recs.length >= MAX_DAOS) return; // cap keeps the invariant sweep cheap

        uint256 initialSupply = bound(supplySeed, 0, 1e27);
        address initialHolder = _actor(holderSeed);
        uint48 votingDelay = uint48(bound(votingDelaySeed, 0, 50));
        uint32 votingPeriod = uint32(bound(votingPeriodSeed, 1, 100)); // OZ requires period > 0
        uint256 quorumPercent = bound(quorumSeed, 0, 100);
        uint256 timelockDelay = bound(timelockSeed, 0, 7 days);
        uint256 proposalThreshold = bound(thresholdSeed, 0, 1e24);

        uint256 fee = factory.fee();
        vm.deal(address(this), fee);

        (address token, address timelock, address governor) = factory.createDao{value: fee}(
            "DAO",
            "Tok",
            "TK",
            initialSupply,
            initialHolder,
            votingDelay,
            votingPeriod,
            quorumPercent,
            timelockDelay,
            proposalThreshold
        );

        recs.push(
            Rec({
                token: token,
                timelock: timelock,
                governor: governor,
                votingDelay: votingDelay,
                votingPeriod: votingPeriod,
                proposalThreshold: proposalThreshold,
                quorumPercent: quorumPercent,
                initialSupply: initialSupply,
                initialHolder: initialHolder
            })
        );
        ghostFeesForwarded += fee;
        ++ghostCreated;
    }

    // --------------------------------------------------------------------- //
    //                        Fee configuration                              //
    // --------------------------------------------------------------------- //

    function setFee(uint256 feeSeed) public {
        factory.setFee(bound(feeSeed, 0, factory.MAX_FEE()));
    }

    // --------------------------------------------------------------------- //
    //                  Exercise a created token's votes                     //
    // --------------------------------------------------------------------- //

    function delegate(uint256 daoSeed, uint256 actorSeed) public {
        if (recs.length == 0) return;
        Rec storage r = recs[bound(daoSeed, 0, recs.length - 1)];
        address a = _actor(actorSeed);
        vm.prank(a);
        DaoToken(r.token).delegate(a);
        selfDelegated[r.token][a] = true;
    }

    function transferToken(uint256 daoSeed, uint256 fromSeed, uint256 toSeed, uint256 amtSeed) public {
        if (recs.length == 0) return;
        Rec storage r = recs[bound(daoSeed, 0, recs.length - 1)];
        DaoToken token = DaoToken(r.token);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amt = bound(amtSeed, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amt);
    }
}
